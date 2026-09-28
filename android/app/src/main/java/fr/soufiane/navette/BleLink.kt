package fr.soufiane.navette

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.ParcelUuid
import android.util.Log
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.SocketTimeoutException
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.Semaphore
import java.util.concurrent.TimeUnit

/**
 * Liaison Bluetooth basse consommation avec le Mac, pour quand ils n'ont aucun réseau en commun
 * (voir « Bluetooth link » dans PROTOCOL.md). Le téléphone publie un service GATT et s'annonce ; le
 * Mac s'y connecte, écrit dans [TO_PHONE] et reçoit les notifications de [TO_MAC]. Les octets forment
 * le même flux de trames que la liaison Wi-Fi : [LocalLink] s'occupe de la poignée de main et des
 * messages.
 *
 * Indépendante de la connexion mains-libres qui déclenche le point d'accès (Bluetooth classique,
 * coupée par le Mac au bout de 15 s) : une liaison BLE n'est pas un profil connecté pour Android.
 */
@SuppressLint("MissingPermission") // vérifiées par hasPermissions() avant tout appel
object BleLink {
    val SERVICE: UUID = UUID.fromString("8f1d3c52-6a4e-4b8e-9d1b-5a7c2e0f4a10")
    /** Le Mac y écrit (écriture sans réponse). */
    val TO_PHONE: UUID = UUID.fromString("8f1d3c52-6a4e-4b8e-9d1b-5a7c2e0f4a11")
    /** Le téléphone y notifie le Mac. */
    val TO_MAC: UUID = UUID.fromString("8f1d3c52-6a4e-4b8e-9d1b-5a7c2e0f4a12")
    private val CCCD: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    private const val TAG = "NavetteBle"

    private var context: Context? = null
    @Volatile private var server: BluetoothGattServer? = null
    private var toMac: BluetoothGattCharacteristic? = null
    private var advertising = false
    private var receiverRegistered = false
    private val channels = ConcurrentHashMap<String, BleChannel>()
    private val mtus = ConcurrentHashMap<String, Int>()

    /** Pour l'écran principal. */
    @Volatile var status: String = "arrêté"
        private set

    fun hasPermissions(context: Context): Boolean = listOf(
        Manifest.permission.BLUETOOTH_ADVERTISE, Manifest.permission.BLUETOOTH_CONNECT,
    ).all { context.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }

    @Synchronized
    fun start(context: Context) {
        this.context = context.applicationContext
        if (!receiverRegistered) {
            context.applicationContext.registerReceiver(adapterReceiver, IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED))
            receiverRegistered = true
        }
        open()
    }

    /** Après l'octroi de l'autorisation « Appareils à proximité ». */
    fun refresh() = synchronized(this) { if (context != null) open() }

    @Synchronized
    fun stop() {
        close("arrêté")
        if (receiverRegistered) runCatching { context?.unregisterReceiver(adapterReceiver) }
        receiverRegistered = false
        context = null
    }

    private val adapterReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            when (intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, -1)) {
                BluetoothAdapter.STATE_ON -> synchronized(this@BleLink) { open() }
                BluetoothAdapter.STATE_TURNING_OFF, BluetoothAdapter.STATE_OFF ->
                    synchronized(this@BleLink) { close("Bluetooth désactivé") }
            }
        }
    }

    private fun open() {
        val ctx = context ?: return
        if (server != null) return
        if (!hasPermissions(ctx)) {
            status = "autorisation « Appareils à proximité » manquante"
            return
        }
        val manager = ctx.getSystemService(BluetoothManager::class.java)
        if (manager?.adapter?.isEnabled != true) {
            status = "Bluetooth désactivé"
            return
        }
        val gatt = manager.openGattServer(ctx, callback) ?: run {
            status = "Bluetooth indisponible"
            return
        }
        server = gatt
        val characteristic = BluetoothGattCharacteristic(
            TO_MAC, BluetoothGattCharacteristic.PROPERTY_NOTIFY, BluetoothGattCharacteristic.PERMISSION_READ,
        ).apply {
            addDescriptor(BluetoothGattDescriptor(
                CCCD, BluetoothGattDescriptor.PERMISSION_READ or BluetoothGattDescriptor.PERMISSION_WRITE,
            ))
        }
        toMac = characteristic
        val service = BluetoothGattService(SERVICE, BluetoothGattService.SERVICE_TYPE_PRIMARY).apply {
            addCharacteristic(BluetoothGattCharacteristic(
                TO_PHONE,
                BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE or BluetoothGattCharacteristic.PROPERTY_WRITE,
                BluetoothGattCharacteristic.PERMISSION_WRITE,
            ))
            addCharacteristic(characteristic)
        }
        gatt.addService(service) // la publication commence dans onServiceAdded
    }

    private fun close(reason: String) {
        stopAdvertising()
        channels.values.forEach { it.close() }
        channels.clear()
        runCatching { server?.close() }
        server = null
        toMac = null
        status = reason
    }

    // --- Annonce ---

    private fun advertise() {
        val adapter = context?.getSystemService(BluetoothManager::class.java)?.adapter ?: return
        val advertiser = adapter.bluetoothLeAdvertiser ?: return
        if (advertising) return
        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_BALANCED)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM)
            .setConnectable(true)
            .setTimeout(0)
            .build()
        val data = AdvertiseData.Builder()
            .addServiceUuid(ParcelUuid(SERVICE))
            .setIncludeDeviceName(false)
            .build()
        runCatching { advertiser.startAdvertising(settings, data, advertiseCallback) }
            .onSuccess { advertising = true }
            .onFailure { Log.w(TAG, "annonce impossible", it) }
    }

    private fun stopAdvertising() {
        if (!advertising) return
        runCatching {
            context?.getSystemService(BluetoothManager::class.java)?.adapter?.bluetoothLeAdvertiser
                ?.stopAdvertising(advertiseCallback)
        }
        advertising = false
    }

    private val advertiseCallback = object : AdvertiseCallback() {
        override fun onStartSuccess(settingsInEffect: AdvertiseSettings) {
            status = "en attente du Mac"
            Log.i(TAG, "annonce BLE active")
        }

        override fun onStartFailure(errorCode: Int) {
            advertising = errorCode == ADVERTISE_FAILED_ALREADY_STARTED
            status = "annonce Bluetooth refusée ($errorCode)"
            Log.w(TAG, "annonce BLE refusée ($errorCode)")
        }
    }

    // --- Serveur GATT ---

    private val callback = object : BluetoothGattServerCallback() {
        override fun onServiceAdded(status: Int, service: BluetoothGattService) {
            if (status == BluetoothGatt.GATT_SUCCESS) synchronized(this@BleLink) { advertise() }
        }

        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                channels.remove(device.address)?.close()
                mtus.remove(device.address)
                // Certaines piles arrêtent l'annonce à la connexion : on la relance.
                synchronized(this@BleLink) {
                    stopAdvertising()
                    if (server != null) advertise()
                }
            }
        }

        override fun onMtuChanged(device: BluetoothDevice, mtu: Int) {
            mtus[device.address] = mtu
            channels[device.address]?.mtu = mtu
        }

        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice, requestId: Int, characteristic: BluetoothGattCharacteristic,
            preparedWrite: Boolean, responseNeeded: Boolean, offset: Int, value: ByteArray,
        ) {
            val ok = characteristic.uuid == TO_PHONE && !preparedWrite && offset == 0
            if (ok) channel(device).feed(value)
            if (responseNeeded) {
                server?.sendResponse(device, requestId,
                    if (ok) BluetoothGatt.GATT_SUCCESS else BluetoothGatt.GATT_REQUEST_NOT_SUPPORTED, 0, null)
            }
        }

        override fun onDescriptorWriteRequest(
            device: BluetoothDevice, requestId: Int, descriptor: BluetoothGattDescriptor,
            preparedWrite: Boolean, responseNeeded: Boolean, offset: Int, value: ByteArray,
        ) {
            if (responseNeeded) server?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null)
            // Le Mac s'abonne aux notifications : la session peut commencer.
            if (descriptor.uuid == CCCD && value.contentEquals(BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)) {
                channel(device)
            }
        }

        override fun onNotificationSent(device: BluetoothDevice, status: Int) {
            channels[device.address]?.onSent()
        }
    }

    /** Canal du Mac [device], créé (avec sa session) à la première occasion. */
    private fun channel(device: BluetoothDevice): BleChannel =
        channels.computeIfAbsent(device.address) { address ->
            BleChannel(device).also { channel ->
                channel.mtu = mtus[address] ?: 23
                Log.i(TAG, "Mac connecté en Bluetooth")
                Thread({
                    LocalLink.serveBluetooth(channel)
                    channels.remove(address, channel)
                }, "navette-ble-mac").start()
            }
        }

    /** Flux d'octets sur la liaison BLE : écritures du Mac en entrée, notifications en sortie. */
    private class BleChannel(private val device: BluetoothDevice) : LocalLink.Channel {
        @Volatile var mtu = 23
        @Volatile private var closed = false
        @Volatile private var timeoutMs = 0
        private val incoming = LinkedBlockingQueue<ByteArray>()
        private val sent = Semaphore(0)

        override val address: String = "Bluetooth"

        fun feed(bytes: ByteArray) {
            if (!closed) incoming.offer(bytes.copyOf())
        }

        fun onSent() = sent.release()

        override fun setReadTimeout(ms: Int) { timeoutMs = ms }

        override fun close() {
            if (closed) return
            closed = true
            incoming.offer(END)
            sent.release()
            runCatching { server?.cancelConnection(device) }
        }

        override val input: InputStream = object : InputStream() {
            private var current: ByteArray? = null
            private var position = 0

            override fun read(): Int {
                val one = ByteArray(1)
                return if (read(one, 0, 1) < 0) -1 else one[0].toInt() and 0xff
            }

            override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
                if (length == 0) return 0
                var chunk = current
                while (chunk == null || position >= chunk.size) {
                    val next = if (timeoutMs > 0) {
                        incoming.poll(timeoutMs.toLong(), TimeUnit.MILLISECONDS)
                            ?: throw SocketTimeoutException("Bluetooth : rien reçu du Mac")
                    } else {
                        incoming.take()
                    }
                    if (next === END) {
                        incoming.offer(END) // lectures suivantes : fin aussi
                        return -1
                    }
                    chunk = next
                    current = next
                    position = 0
                }
                val n = minOf(length, chunk.size - position)
                System.arraycopy(chunk, position, buffer, offset, n)
                position += n
                return n
            }
        }

        override val output: OutputStream = object : OutputStream() {
            override fun write(b: Int) = write(byteArrayOf(b.toByte()), 0, 1)

            /**
             * Découpe en notifications de (MTU − 3) octets, 512 au plus (taille maximale d'un attribut,
             * imposée par Android), une à la fois (accusé onNotificationSent).
             */
            override fun write(bytes: ByteArray, offset: Int, length: Int) {
                var index = offset
                var busy = 0
                while (index < offset + length) {
                    if (closed) throw IOException("liaison Bluetooth fermée")
                    val gatt = server ?: throw IOException("Bluetooth arrêté")
                    val characteristic = toMac ?: throw IOException("Bluetooth arrêté")
                    val n = minOf(mtu - 3, MAX_ATTRIBUTE, offset + length - index)
                    val result = gatt.notifyCharacteristicChanged(
                        device, characteristic, false, bytes.copyOfRange(index, index + n),
                    )
                    if (result != BluetoothStatusCodes.SUCCESS) {
                        // File de la pile pleine : on réessaie un peu plus tard.
                        if (++busy > 200) throw IOException("notification refusée ($result)")
                        Thread.sleep(10)
                        continue
                    }
                    busy = 0
                    if (!sent.tryAcquire(5, TimeUnit.SECONDS)) throw IOException("Bluetooth : pas d’accusé du Mac")
                    index += n
                }
            }
        }

        companion object {
            private val END = ByteArray(0)
            private const val MAX_ATTRIBUTE = 512
        }
    }
}

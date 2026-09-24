package fr.soufiane.navette

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.app.AlertDialog
import android.app.StatusBarManager
import android.content.ClipboardManager
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.drawable.Icon
import android.net.Uri
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings as AndroidSettings
import android.text.InputType
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.Switch
import android.widget.TextView
import android.widget.Toast
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.codescanner.GmsBarcodeScannerOptions
import com.google.mlkit.vision.codescanner.GmsBarcodeScanning

class MainActivity : Activity() {
    private lateinit var settings: Settings
    private lateinit var status: TextView
    private lateinit var server: TextView
    private lateinit var pairedActions: View
    private lateinit var batteryButton: Button
    private lateinit var autoStatus: TextView
    private lateinit var autoSwitch: Switch
    private lateinit var overlayButton: Button
    private lateinit var notifSwitch: Switch
    private lateinit var notifStatus: TextView
    private lateinit var notifButton: Button
    private lateinit var phoneStatus: TextView
    private lateinit var phonePermissionButton: Button
    private val stateListener: () -> Unit = { render() }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        settings = Settings(this)
        buildUi()
        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
        }
        if (settings.isPaired) RelayService.start(this)
        handlePairingLink(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handlePairingLink(intent)
    }

    /** Lien navette://pair ouvert depuis l'appareil photo : on confirme avant d'appliquer,
     *  car n'importe quelle page web pourrait ouvrir ce lien vers un autre serveur. */
    private fun handlePairingLink(intent: Intent?) {
        val uri = intent?.takeIf { it.action == Intent.ACTION_VIEW }?.data ?: return
        setIntent(Intent(this, MainActivity::class.java))
        val server = uri.getQueryParameter("u") ?: return
        AlertDialog.Builder(this)
            .setTitle("Appairer avec ce Mac ?")
            .setMessage("Serveur : $server\n\nN’acceptez que si ce code vient de votre propre Mac.")
            .setPositiveButton("Appairer") { _, _ -> applyPairing(uri.toString()) }
            .setNegativeButton("Annuler", null)
            .show()
    }

    private fun applyPairing(raw: String) {
        if (settings.applyPairingUri(raw)) {
            Toast.makeText(this, "Appairé ✓", Toast.LENGTH_SHORT).show()
            RelayService.start(this, reconnect = true)
            render()
        } else {
            Toast.makeText(this, "Ce n’est pas un code Navette", Toast.LENGTH_LONG).show()
        }
    }

    override fun onResume() {
        super.onResume()
        Relay.addListener(stateListener)
        // Une autorisation vient peut-être d'être accordée (réglages ou ADB) : le service réévalue.
        if (settings.isPaired) RelayService.refresh(this)
        render()
    }

    override fun onPause() {
        Relay.removeListener(stateListener)
        super.onPause()
    }

    // --- Interface (construite en code : un seul écran, pas besoin de plus) ---

    private fun dp(v: Int) = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v.toFloat(), resources.displayMetrics).toInt()

    private fun buildUi() {
        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(24), dp(16), dp(24), dp(32))
        }
        fun text(value: String, size: Float = 16f, bold: Boolean = false) = TextView(this).apply {
            text = value
            textSize = size
            if (bold) setTypeface(typeface, android.graphics.Typeface.BOLD)
            setPadding(0, dp(6), 0, dp(6))
        }
        fun button(label: String, onClick: () -> Unit) = Button(this).apply {
            text = label
            isAllCaps = false
            setOnClickListener { onClick() }
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT)
                .apply { topMargin = dp(8) }
        }

        column.addView(text("Presse-papier partagé avec le Mac", 15f))
        status = text("", 18f, bold = true).apply { setPadding(0, dp(20), 0, dp(4)) }
        column.addView(status)
        server = text("", 13f)
        column.addView(server)

        column.addView(button("Scanner le code du Mac") { scan() })

        pairedActions = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            addView(button("Envoyer le presse-papier au Mac") { sendClipboard() })
            addView(button("Récupérer le dernier élément") { fetchLast() })

            addView(text("Envoi automatique", 18f, bold = true).apply { setPadding(0, dp(24), 0, dp(4)) })
            autoSwitch = Switch(this@MainActivity).apply {
                text = "Envoyer au Mac chaque copie"
                textSize = 16f
                setOnCheckedChangeListener { _, checked ->
                    if (checked == settings.autoSend) return@setOnCheckedChangeListener
                    settings.autoSend = checked
                    RelayService.refresh(this@MainActivity)
                    render()
                }
            }
            addView(autoSwitch)
            autoStatus = text("", 14f)
            addView(autoStatus)
            overlayButton = button("Autoriser « Apparaître au-dessus »") {
                startActivity(Intent(AndroidSettings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:$packageName")))
            }
            addView(overlayButton)

            addView(text("Notifications sur le Mac", 18f, bold = true).apply { setPadding(0, dp(24), 0, dp(4)) })
            notifSwitch = Switch(this@MainActivity).apply {
                text = "Afficher mes notifications sur le Mac"
                textSize = 16f
                setOnCheckedChangeListener { _, checked -> settings.forwardNotifications = checked }
            }
            addView(notifSwitch)
            notifStatus = text("", 14f)
            addView(notifStatus)
            notifButton = button("Autoriser l’accès aux notifications") {
                startActivity(
                    Intent(AndroidSettings.ACTION_NOTIFICATION_LISTENER_DETAIL_SETTINGS)
                        .putExtra(
                            AndroidSettings.EXTRA_NOTIFICATION_LISTENER_COMPONENT_NAME,
                            ComponentName(this@MainActivity, NotifListener::class.java).flattenToString(),
                        ),
                )
            }
            addView(notifButton)

            addView(text("État du téléphone sur le Mac", 18f, bold = true).apply { setPadding(0, dp(24), 0, dp(4)) })
            phoneStatus = text("", 14f)
            addView(phoneStatus)
            phonePermissionButton = button("Afficher le réseau (5G/4G) sur le Mac") {
                requestPermissions(arrayOf(Manifest.permission.READ_PHONE_STATE), REQUEST_PHONE)
            }
            addView(phonePermissionButton)
            addView(text("Raccourcis", 18f, bold = true).apply { setPadding(0, dp(24), 0, dp(4)) })
            addView(text(
                "• Tuile « Envoyer au Mac » dans les réglages rapides : copiez, descendez le volet, touchez-la.\n" +
                    "• Sélectionnez un texte → menu ⋮ → « Envoyer au Mac ».\n" +
                    "• Partager → Navette, depuis n’importe quelle app.\n" +
                    "• Partager un lien → « Ouvrir sur le Mac ».\n" +
                    "• Ce que vous copiez sur le Mac arrive directement dans le presse-papier du téléphone.",
                14f,
            ))
            addView(button("Ajouter la tuile aux réglages rapides") { addTile() })
            batteryButton = button("Autoriser Navette en arrière-plan (batterie)") { askBatteryExemption() }
            addView(batteryButton)
            addView(button("Modifier l’adresse du serveur") { editServer() })
            addView(button("Se reconnecter") { RelayService.start(this@MainActivity, reconnect = true) })
        }
        column.addView(pairedActions)

        setContentView(ScrollView(this).apply { addView(column) })
    }

    private fun render() {
        if (!settings.isPaired) {
            status.text = "Pas encore appairé"
            server.text = "Sur le Mac : menu Navette › Appairer le téléphone…, puis scannez le code."
            pairedActions.visibility = View.GONE
            return
        }
        pairedActions.visibility = View.VISIBLE
        status.text = when (Relay.state) {
            Relay.State.CONNECTED -> "● Connecté"
            Relay.State.CONNECTING -> "◌ Connexion…"
            Relay.State.UNAUTHORIZED -> "⚠ Jeton refusé par le serveur"
            Relay.State.ERROR -> "○ Hors ligne — ${Relay.detail}"
            Relay.State.OFF -> "○ Arrêté"
        }
        server.text = "Serveur : ${settings.server}"
        val logs = AutoCopy.hasReadLogs(this)
        val overlay = AutoCopy.hasOverlay(this)
        val notifs = NotifListener.isEnabled(this)
        notifSwitch.isChecked = settings.forwardNotifications
        notifSwitch.isEnabled = notifs
        notifButton.visibility = if (notifs) View.GONE else View.VISIBLE
        notifStatus.text = if (notifs) {
            "Les notifications importantes s’affichent sur le Mac ; répondez aux messages depuis la notification. " +
                "Les notifications silencieuses restent sur le téléphone."
        } else {
            "Autorisez Navette à lire les notifications pour les voir sur le Mac."
        }
        val network = NetworkStatus.current
        phonePermissionButton.visibility =
            if (network != null && !network.networkTypeAvailable) View.VISIBLE else View.GONE
        phoneStatus.text = when {
            network == null -> "Démarrage…"
            network.networkTypeAvailable ->
                "Transmis au Mac : ${network.label.ifEmpty { "réseau inconnu" }} · ${network.bars}/4 barres, avec la batterie."
            else ->
                "Transmis au Mac : ${network.bars}/4 barres et la batterie. Android demande l’autorisation « Téléphone » " +
                    "pour indiquer aussi 5G/4G (Navette ne lit ni vos appels ni votre numéro)."
        }
        autoSwitch.isChecked = settings.autoSend
        autoSwitch.isEnabled = logs && overlay
        overlayButton.visibility = if (overlay) View.GONE else View.VISIBLE
        autoStatus.text = when {
            !logs -> "① Autorisation « journaux » manquante : branchez le téléphone au Mac et lancez " +
                "android/scripts/activer-auto.sh (une seule fois).\n" +
                (if (overlay) "② « Apparaître au-dessus » : OK" else "② Autorisez « Apparaître au-dessus » ci-dessous.")
            !overlay -> "① Journaux : OK\n② Autorisez « Apparaître au-dessus » ci-dessous."
            !settings.autoSend -> "En pause : utilisez la tuile ou la notification."
            RelayService.autoAccess == AutoCopy.Access.DENIED ->
                "Accès aux journaux refusé. Quittez Navette, attendez une minute, rouvrez-la et " +
                    "acceptez la demande d’accès aux journaux."
            RelayService.autoAccess == AutoCopy.Access.CHECKING -> "Vérification… (acceptez la demande d’accès aux journaux)"
            RelayService.autoAccess == AutoCopy.Access.GRANTED -> "Actif : ce que vous copiez part tout seul vers le Mac."
            else -> "Démarrage…"
        }
        val power = getSystemService(PowerManager::class.java)
        batteryButton.visibility = if (power.isIgnoringBatteryOptimizations(packageName)) View.GONE else View.VISIBLE
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQUEST_PHONE) RelayService.refresh(this)
    }

    // --- Actions ---

    private fun scan() {
        val options = GmsBarcodeScannerOptions.Builder().setBarcodeFormats(Barcode.FORMAT_QR_CODE).build()
        GmsBarcodeScanning.getClient(this, options).startScan()
            .addOnSuccessListener { code -> applyPairing(code.rawValue ?: "") }
            .addOnFailureListener { Toast.makeText(this, "Scanner indisponible : ${it.message}", Toast.LENGTH_LONG).show() }
    }

    private fun sendClipboard() {
        // Cette activité a le focus : on peut lire le presse-papier directement.
        val content = ClipContent.fromClip(this, getSystemService(ClipboardManager::class.java).primaryClip)
        if (content == null) {
            Toast.makeText(this, "Presse-papier vide", Toast.LENGTH_SHORT).show()
            return
        }
        Relay.send(settings, content) { error ->
            Toast.makeText(this, error ?: "Envoyé au Mac ✓", Toast.LENGTH_SHORT).show()
        }
    }

    private fun fetchLast() {
        Relay.fetchLast(settings) { content, error ->
            if (content != null) {
                Clipboard.write(this, content)
                Toast.makeText(this, "Copié : ${content.preview}", Toast.LENGTH_SHORT).show()
            } else {
                Toast.makeText(this, error, Toast.LENGTH_SHORT).show()
            }
        }
    }

    private fun addTile() {
        getSystemService(StatusBarManager::class.java).requestAddTileService(
            ComponentName(this, SendTileService::class.java),
            "Envoyer au Mac",
            Icon.createWithResource(this, R.drawable.ic_navette),
            mainExecutor,
        ) { }
    }

    @SuppressLint("BatteryLife")
    private fun askBatteryExemption() {
        // Sans cette exemption, One UI finit par couper la connexion quand l'écran est éteint.
        startActivity(
            Intent(AndroidSettings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:$packageName")),
        )
    }

    private fun editServer() {
        val field = EditText(this).apply {
            setText(settings.server)
            inputType = InputType.TYPE_TEXT_VARIATION_URI
            gravity = Gravity.START
        }
        AlertDialog.Builder(this)
            .setTitle("Adresse du serveur")
            .setMessage("Ex. http://192.168.1.10:3200 sur votre réseau, ou l’adresse Tailscale de votre serveur")
            .setView(field)
            .setPositiveButton("Enregistrer") { _, _ ->
                val value = field.text.toString().trim()
                if (value.startsWith("http://") || value.startsWith("https://")) {
                    settings.server = value
                    RelayService.start(this, reconnect = true)
                    render()
                } else {
                    Toast.makeText(this, "L’adresse doit commencer par http:// ou https://", Toast.LENGTH_LONG).show()
                }
            }
            .setNegativeButton("Annuler", null)
            .show()
    }

    companion object {
        private const val REQUEST_PHONE = 2
    }
}

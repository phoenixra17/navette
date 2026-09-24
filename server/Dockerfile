FROM node:22-alpine
WORKDIR /app
ENV NODE_ENV=production
COPY package.json package-lock.json ./
RUN npm ci --omit=dev
COPY src ./src
# Les datasets TrueNAS peuvent imposer des droits restrictifs aux fichiers copiés :
# on les rend lisibles pour l'utilisateur non root qui exécute le serveur.
RUN chmod -R a+rX /app
USER node
EXPOSE 3200
CMD ["node", "src/index.js"]

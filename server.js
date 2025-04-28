// server.js
// Polyfill fetch pour Google Auth (nécessaire au SDK Admin pour générer des OAuth tokens)
const fetch = require('node-fetch');
globalThis.fetch = fetch;

// Micro-service HTTP pour envoyer des notifications FCM v1 avec Firebase Admin SDK
require('dotenv').config();
const express = require('express');
const cors = require('cors');
const bodyParser = require('body-parser');
const admin = require('firebase-admin');
const nodemailer = require('nodemailer');
const fs = require('fs');
const path = require('path');

// Configuration Gmail
const transporter = nodemailer.createTransport({
  service: 'gmail',
  auth: {
    user: 'khalilouerghemmi@gmail.com',
    pass: 'uwlu gnhq lnkt fist' // Mot de passe d'application Gmail
  }
});

const serviceAccountPath = fs.existsSync('./service-account.json')
  ? './service-account.json'
  : '/etc/secrets/service-account.json';

const serviceAccount = require(serviceAccountPath);

// Initialisation de Firebase Admin SDK
admin.initializeApp({
  credential: admin.credential.cert(serviceAccount),
});

const app = express();
app.use(cors());                // Autorise les requêtes cross-origin
app.use(bodyParser.json());     // Pour parser les corps JSON

// Endpoint GET pour vérifier que le serveur est bien en ligne
app.get('/sendNotification', (req, res) => {
  res.send('Serveur Mail prêt. Envoyez un POST JSON {title, body, conversationId}');
});

// Endpoint POST pour envoyer une notification par e-mail via Gmail
app.post('/sendNotification', async (req, res) => {
  const { title, body, conversationId } = req.body;
  if (!title || !body || !conversationId) {
    return res.status(400).json({ error: 'title, body et conversationId sont requis.' });
  }
  try {
    // Vérifier si la conversation est déjà verrouillée
    const conversationRef = admin.firestore().collection('conversations').doc(conversationId);
    const conversationDoc = await conversationRef.get();
    
    if (!conversationDoc.exists) {
      return res.status(404).json({ error: 'Conversation non trouvée.' });
    }
    
    const conversationData = conversationDoc.data();
    
    // Si la conversation est déjà verrouillée, ne pas envoyer d'email
    if (conversationData.isLocked) {
      return res.status(409).json({ error: 'La conversation est déjà verrouillée par un réceptionniste.' });
    }
    
    // Récupérer tous les réceptionnistes
    const snapshot = await admin.firestore().collection('receptionists').get();
    if (snapshot.empty) {
      return res.status(404).json({ error: 'Aucun réceptionniste trouvé.' });
    }
    
    const emails = snapshot.docs
      .map(doc => doc.data().email)
      .filter(email => email);
      
    if (emails.length === 0) {
      return res.status(404).json({ error: 'Aucun e-mail trouvé.' });
    }
    
    // Créer un lien unique pour cette conversation
    const conversationLink = `http://localhost:3000/conversation/${conversationId}`;
    
    // Préparer l'e-mail Gmail
    const mailOptions = {
      from: 'khalilouerghemmi@gmail.com',
      to: emails.join(', '),
      subject: title,
      text: `${body}\n\nCliquez sur ce lien pour rejoindre la conversation: ${conversationLink}`,
      html: `
        <div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto;">
          <h2 style="color: #4285F4;">${title}</h2>
          <p style="font-size: 16px; line-height: 1.5;">${body}</p>
          <div style="margin-top: 20px; text-align: center;">
            <a href="${conversationLink}" style="background-color: #4285F4; color: white; padding: 10px 20px; text-decoration: none; border-radius: 5px; font-weight: bold;">Rejoindre la conversation</a>
          </div>
          <p style="margin-top: 20px; font-size: 14px; color: #666;">Note: Seul le premier réceptionniste à cliquer sur le lien pourra rejoindre la conversation.</p>
        </div>
      `
    };
    
    // Envoyer l'email
    const info = await transporter.sendMail(mailOptions);
    console.log(`E-mails envoyés via Gmail: ${info.messageId}`);
    
    // Marquer la conversation comme en attente de réceptionniste
    await conversationRef.update({
      isEscalated: true,
      isLocked: false,
      waitingForReceptionist: true,
      lastUpdated: admin.firestore.FieldValue.serverTimestamp()
    });
    
    return res.json({ 
      success: true, 
      sentTo: emails, 
      messageId: info.messageId,
      conversationId: conversationId
    });
  } catch (error) {
    console.error('Erreur envoi e-mail :', error);
    return res.status(500).json({ error: error.message });
  }
});

// Endpoint pour verrouiller une conversation pour un réceptionniste
app.post('/lockConversation', async (req, res) => {
  const { conversationId, receptionistEmail } = req.body;
  
  if (!conversationId || !receptionistEmail) {
    return res.status(400).json({ error: 'conversationId et receptionistEmail sont requis.' });
  }
  
  try {
    const conversationRef = admin.firestore().collection('conversations').doc(conversationId);
    const conversationDoc = await conversationRef.get();
    
    if (!conversationDoc.exists) {
      return res.status(404).json({ error: 'Conversation non trouvée.' });
    }
    
    const conversationData = conversationDoc.data();
    
    // Si la conversation est déjà verrouillée par un autre réceptionniste
    if (conversationData.isLocked && conversationData.lockedBy !== receptionistEmail) {
      return res.status(409).json({ 
        error: 'La conversation est déjà verrouillée par un autre réceptionniste.',
        lockedBy: conversationData.lockedBy
      });
    }
    
    // Verrouiller la conversation pour ce réceptionniste
    await conversationRef.update({
      isLocked: true,
      lockedBy: receptionistEmail,
      waitingForReceptionist: false,
      lastUpdated: admin.firestore.FieldValue.serverTimestamp()
    });
    
    return res.json({ 
      success: true, 
      message: 'Conversation verrouillée avec succès.',
      conversationId: conversationId,
      receptionistEmail: receptionistEmail
    });
  } catch (error) {
    console.error('Erreur verrouillage conversation :', error);
    return res.status(500).json({ error: error.message });
  }
});

// Endpoint pour récupérer les détails d'une conversation
app.get('/conversation/:conversationId', async (req, res) => {
  const { conversationId } = req.params;
  
  try {
    const conversationRef = admin.firestore().collection('conversations').doc(conversationId);
    const conversationDoc = await conversationRef.get();
    
    if (!conversationDoc.exists) {
      return res.status(404).json({ error: 'Conversation non trouvée.' });
    }
    
    const conversationData = conversationDoc.data();
    
    return res.json({
      success: true,
      conversation: {
        id: conversationId,
        ...conversationData
      }
    });
  } catch (error) {
    console.error('Erreur récupération conversation :', error);
    return res.status(500).json({ error: error.message });
  }
});

// Lancement du serveur sur le port 3000
const PORT = process.env.PORT || 3000;
app.listen(PORT, '0.0.0.0', () => {
  console.log(`Server running on port ${PORT}`);
}); 
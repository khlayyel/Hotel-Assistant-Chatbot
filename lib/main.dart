import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:firebase_core/firebase_core.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'firebase_options.dart';  // Import the Firebase options file
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/services.dart' show rootBundle;

void main() async{
    WidgetsFlutterBinding.ensureInitialized();
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform, // Use the generated options
    );
    if (kIsWeb) {
      FirebaseMessaging messaging = FirebaseMessaging.instance;
      messaging.requestPermission().then((_) {
        messaging.getToken().then((token) {
          print("FCM Token: $token");
        }).catchError((e) {
          print("Error getting FCM token: $e");
        });
      });
    }    runApp(HotelChatbotApp());
  }


class HotelChatbotApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Hotel Assistant Chatbot',
      theme: ThemeData.dark(),
      home: ChatScreen(),
    );
  }
}

class ChatScreen extends StatefulWidget {
  @override
  State createState() => ChatScreenState();
}

class ChatScreenState extends State<ChatScreen> {
  String? _conversationId;
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  final List<ChatMessage> _messages = [];
  bool _showWelcomeMessage = true;
  bool _isTyping = false;
  List<String> userHistory = []; // Store user actions for the resume
  FirebaseMessaging messaging = FirebaseMessaging.instance;
  // Récupérer la clé serveur depuis la console Firebase (Cloud Messaging > Legacy Server key)
  final String fcmServerKey = 'VOTRE_LEGACY_SERVER_KEY';
  final ScrollController _scrollController = ScrollController();

  final String apiKey = "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";
  final String apiUrl = "https://openrouter.ai/api/v1/chat/completions";
  String email = "khalilouerghemmi@gmail.com";

  // Création d'une conversation dans Firestore
  Future<void> _createConversation() async {
    final docRef = await FirebaseFirestore.instance.collection('conversations').add({
      'createdAt': FieldValue.serverTimestamp(),
      'isEscalated': false,
      'isLocked': false,
      'waitingForReceptionist': false,
      'lastUpdated': FieldValue.serverTimestamp(),
    });
    setState(() {
      _conversationId = docRef.id;
    });
    print('Conversation créée avec ID: $_conversationId');
  }

  // Envoie une notification FCM directement via HTTP
  Future<void> _sendPushNotification() async {
    try {
      // Récupère le token du réceptionniste
      final snap = await FirebaseFirestore.instance
          .collection('receptionists')
          .where('email', isEqualTo: email)
          .limit(1)
          .get();
      if (snap.docs.isEmpty) {
        print('Aucun réceptionniste trouvé.');
        return;
      }
      final token = snap.docs.first.data()['fcmToken'];
      final payload = {
        'notification': {
          'title': 'Client en attente',
          'body': 'Un client attend votre assistance !',
        },
        'to': token,
      };
      final response = await http.post(
        Uri.parse('https://fcm.googleapis.com/fcm/send'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'key=$fcmServerKey',
        },
        body: jsonEncode(payload),
      );
      if (response.statusCode == 200) print('Push FCM envoyé.');
      else print('Erreur FCM: ${response.body}');
    } catch (e) {
      print('Erreur push notification: $e');
    }
  }

  Future<bool> _isFallbackResponse(String response) async {
    try {
      // Charger le fichier JSON
      final String jsonString = await rootBundle.loadString('lib/data/fallback_responses.json');
      final Map<String, dynamic> fallbackData = json.decode(jsonString);
      final lowercaseResponse = response.toLowerCase();
      
      // Parcourir toutes les langues
      for (var language in fallbackData['fallback_responses'].keys) {
        var languageData = fallbackData['fallback_responses'][language];
        
        // Parcourir toutes les catégories pour chaque langue
        for (var category in languageData.keys) {
          var phrases = languageData[category] as List<dynamic>;
          
          // Vérifier chaque phrase dans la catégorie
          for (var phrase in phrases) {
            if (lowercaseResponse.contains(phrase.toLowerCase())) {
              return true;
            }
          }
        }
      }
      
      return false;
    } catch (e) {
      print('Erreur lors de la vérification de la réponse: $e');
      return false;
    }
  }

  void _sendMessage() async {
    // Créer la conversation si nécessaire
    if (_conversationId == null) {
      await _createConversation();
    }
    if (_controller.text.isEmpty) return;

    String userMessage = _controller.text.trim();
    _controller.clear();

    if (_showWelcomeMessage) {
      setState(() {
        _showWelcomeMessage = false;
      });
    }

    setState(() {
      _messages.add(ChatMessage(text: userMessage, isUser: true));
      _isTyping = true;
      _messages.add(ChatMessage(text: "Bot is typing...", isUser: false, isTemporary: true));
    });

    // Sauvegarder le message de l'utilisateur dans Firestore
    try {
      await FirebaseFirestore.instance
          .collection('conversations')
          .doc(_conversationId)
          .collection('messages')
          .add({
        'text': userMessage,
        'isUser': true,
        'timestamp': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      print('Erreur sauvegarde message: $e');
    }

    // Save the user actions to history with more detailed tracking
    if (userMessage.toLowerCase().contains("palestine")) {
      userHistory.add("Client a demandé des informations sur la Palestine");
    } else if (userMessage.toLowerCase().contains("tunisia") || userMessage.toLowerCase().contains("tunisie")) {
      userHistory.add("Client a demandé des informations sur la Tunisie");
    } else if (userMessage.toLowerCase().contains("sorry") || userMessage.toLowerCase().contains("désolé")) {
      userHistory.add("Client a demandé des excuses");
    } else if (userMessage.toLowerCase().contains("chambre") || userMessage.toLowerCase().contains("room")) {
      userHistory.add("Client a posé une question sur les chambres");
    } else if (userMessage.toLowerCase().contains("prix") || userMessage.toLowerCase().contains("tarif") || userMessage.toLowerCase().contains("cost")) {
      userHistory.add("Client a demandé des informations sur les prix");
    } else if (userMessage.toLowerCase().contains("réservation") || userMessage.toLowerCase().contains("booking")) {
      userHistory.add("Client a demandé des informations sur les réservations");
    } else if (userMessage.toLowerCase().contains("service") || userMessage.toLowerCase().contains("spa") || userMessage.toLowerCase().contains("restaurant")) {
      userHistory.add("Client a demandé des informations sur les services");
    } else if (userMessage.toLowerCase().contains("merci") || userMessage.toLowerCase().contains("thank")) {
      userHistory.add("Client a remercié l'assistant");
    } else if (userMessage.toLowerCase().contains("problème") || userMessage.toLowerCase().contains("problem")) {
      userHistory.add("Client a signalé un problème");
    } else {
      userHistory.add("Client a posé une question générale");
    }

    try {
      final response = await http.post(
        Uri.parse(apiUrl),
        headers: {
          'Authorization': 'Bearer $apiKey',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          "model": "microsoft/mai-ds-r1:free",
          "messages": _buildChatContext() + [{"role": "user", "content": userMessage}],
        }),
      );

      String responseBody = utf8.decode(response.bodyBytes);
      print("API Response: $responseBody");

      if (response.statusCode == 200) {
        String botReply = jsonDecode(responseBody)['choices'][0]['message']['content'];

        if (botReply.isEmpty || await _isFallbackResponse(botReply)) {
          setState(() {
            _messages.removeWhere((msg) => msg.isTemporary);
            _messages.add(ChatMessage(
                text: "Je ne suis pas en mesure de tout comprendre, mais je m'améliore continuellement. En attendant, souhaitez-vous que je vous mette en contact avec un conseiller ?",
                isUser: false,
                isTemporary: false));
            _messages.add(ChatMessage(
                text: "", // Empty string to just show the buttons here
                isUser: false,
                isTemporary: false,
                hasButtons: true));
          });
          
          // Sauvegarder la réponse du bot dans Firestore
          try {
            await FirebaseFirestore.instance
                .collection('conversations')
                .doc(_conversationId)
                .collection('messages')
                .add({
              'text': "Je ne suis pas en mesure de tout comprendre, mais je m'améliore continuellement. En attendant, souhaitez-vous que je vous mette en contact avec un conseiller ?",
              'isUser': false,
              'timestamp': FieldValue.serverTimestamp(),
            });
          } catch (e) {
            print('Erreur sauvegarde message bot: $e');
          }
        } else {
          setState(() {
            _messages.removeWhere((msg) => msg.isTemporary);
            _messages.add(ChatMessage(text: botReply, isUser: false));
          });
          
          // Sauvegarder la réponse du bot dans Firestore
          try {
            await FirebaseFirestore.instance
                .collection('conversations')
                .doc(_conversationId)
                .collection('messages')
                .add({
              'text': botReply,
              'isUser': false,
              'timestamp': FieldValue.serverTimestamp(),
            });
          } catch (e) {
            print('Erreur sauvegarde message bot: $e');
          }
          
          _scrollToBottom();
        }
      } else {
        setState(() {
          _messages.removeWhere((msg) => msg.isTemporary);
          _messages.add(ChatMessage(text: "Oops! Something went wrong.", isUser: false));
        });
        
        // Sauvegarder le message d'erreur dans Firestore
        try {
          await FirebaseFirestore.instance
              .collection('conversations')
              .doc(_conversationId)
              .collection('messages')
              .add({
            'text': "Oops! Something went wrong.",
            'isUser': false,
            'timestamp': FieldValue.serverTimestamp(),
          });
        } catch (e) {
          print('Erreur sauvegarde message erreur: $e');
        }
      }
    } catch (e) {
      setState(() {
        _messages.removeWhere((msg) => msg.isTemporary);
        _messages.add(ChatMessage(text: "Failed to connect. Please try again.", isUser: false));
      });
      
      // Sauvegarder le message d'erreur dans Firestore
      try {
        await FirebaseFirestore.instance
            .collection('conversations')
            .doc(_conversationId)
            .collection('messages')
            .add({
          'text': "Failed to connect. Please try again.",
          'isUser': false,
          'timestamp': FieldValue.serverTimestamp(),
        });
      } catch (e) {
        print('Erreur sauvegarde message erreur: $e');
      }
    }

    setState(() {
      _isTyping = false;
    });
    _scrollToBottom();
    _focusNode.requestFocus();
  }

  void _handleEscalationResponse(String response) async {
    // Retirer les boutons d'escalade
    setState(() {
      _messages.removeWhere((msg) => msg.hasButtons == true);
    });
    if (response == "Oui") {
      // Construire le contexte de la conversation pour le résumé
      List<Map<String, String>> conversationContext = _buildChatContext();
      
      try {
        // Appeler l'API pour générer le résumé
        final response = await http.post(
          Uri.parse(apiUrl),
          headers: {
            'Authorization': 'Bearer $apiKey',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            "model": "microsoft/mai-ds-r1:free",
            "messages": [
              {
                "role": "system",
                "content": "Tu es un assistant qui doit faire un résumé concis et clair de la conversation entre le client et le chatbot. Le résumé doit être en français et doit aider le réceptionniste à comprendre rapidement le contexte et les besoins du client. Sois bref et précis."
              },
              ...conversationContext,
              {
                "role": "user",
                "content": "Fais un résumé concis de cette conversation pour le réceptionniste."
              }
            ],
          }),
        );

        if (response.statusCode == 200) {
          String summary = jsonDecode(utf8.decode(response.bodyBytes))['choices'][0]['message']['content'];
          
          setState(() {
            _messages.add(ChatMessage(text: summary, isUser: false));
          });
          
          // Sauvegarder le résumé dans Firestore
          try {
            await FirebaseFirestore.instance
                .collection('conversations')
                .doc(_conversationId)
                .collection('messages')
                .add({
              'text': summary,
              'isUser': false,
              'timestamp': FieldValue.serverTimestamp(),
            });
          } catch (e) {
            print('Erreur sauvegarde résumé: $e');
          }
        }
      } catch (e) {
        print('Erreur génération résumé: $e');
      }

      // Appel du micro-service Node.js qui utilise Admin SDK (API V1)
      try {
        final resp = await http.post(
          Uri.parse('https://hotel-assistant-chatbot.onrender.com/sendNotification'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'title': 'Client en attente',
            'body': 'Il y a un client en attente de votre assistance !',
            'conversationId': _conversationId,
          }),
        );
        if (resp.statusCode == 200) {
          print('Notification envoyée via micro-service');
          setState(() {
            _messages.add(ChatMessage(text: "Un réceptionniste va vous rejoindre bientôt !", isUser: false));
          });
          // Sauvegarder ce message dans Firestore
          try {
            await FirebaseFirestore.instance
                .collection('conversations')
                .doc(_conversationId)
                .collection('messages')
                .add({
              'text': "Un réceptionniste va vous rejoindre bientôt !",
              'isUser': false,
              'timestamp': FieldValue.serverTimestamp(),
            });
          } catch (e) {
            print('Erreur sauvegarde message réceptionniste: $e');
          }
        } else {
          print('Erreur micro-service: ${resp.body}');
          setState(() {
            _messages.add(ChatMessage(text: "Désolé, il y a eu un problème pour contacter un réceptionniste. Veuillez réessayer plus tard.", isUser: false));
          });
        }
      } catch (e) {
        print('Erreur appel micro-service: $e');
        setState(() {
          _messages.add(ChatMessage(text: "Désolé, il y a eu un problème pour contacter un réceptionniste. Veuillez réessayer plus tard.", isUser: false));
        });
      }
    } else {
      setState(() {
        _messages.add(ChatMessage(text: "D'accord, je vais essayer de mieux vous aider.", isUser: false));
      });
    }
    _scrollToBottom();
  }

  String _buildResume() {
    if (userHistory.isEmpty) return "";
    
    // Compter les occurrences de chaque type d'action
    Map<String, int> actionCounts = {};
    for (String action in userHistory) {
      actionCounts[action] = (actionCounts[action] ?? 0) + 1;
    }
    
    // Construire un résumé plus détaillé
    String resume = "Résumé de la conversation :\n\n";
    resume += "Nombre total d'interactions : ${userHistory.length}\n\n";
    resume += "Détail des interactions :\n";
    
    actionCounts.forEach((action, count) {
      resume += "- $action (${count} fois)\n";
    });
    
    return resume;
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  List<Map<String, String>> _buildChatContext() {
    return _messages
        .where((msg) => !msg.isTemporary)
        .map((msg) => {"role": msg.isUser ? "user" : "assistant", "content": msg.text})
        .toList();
  }

  Widget _buildEscalationButtons() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        ElevatedButton(
          onPressed: () => _handleEscalationResponse("Oui"),
          child: Text("Oui"),
          style: ButtonStyle(
            backgroundColor: MaterialStateProperty.all(Colors.blueAccent),
            foregroundColor: MaterialStateProperty.all(Colors.white),
          ),
        ),
        SizedBox(width: 10),
        ElevatedButton(
          onPressed: () => _handleEscalationResponse("Non"),
          child: Text("Non"),
          style: ButtonStyle(
            backgroundColor: MaterialStateProperty.all(Colors.redAccent),
            foregroundColor: MaterialStateProperty.all(Colors.white),
          ),
        ),
      ],
    );
  }

  Widget _buildMessage(ChatMessage message, int index) {
    bool isUser = message.isUser;
    bool isTemporary = message.isTemporary;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      child: Row(
        mainAxisAlignment: isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          if (!isUser)
            CircleAvatar(
              backgroundColor: Colors.grey[700],
              child: Icon(Icons.smart_toy, color: Colors.white),
            ),
          if (!isUser) SizedBox(width: 10),
          Flexible(
            child: Container(
              padding: EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: isUser ? Colors.blueAccent : Colors.grey[800],
                borderRadius: BorderRadius.circular(12),
              ),
              child: isTemporary
                  ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.0,
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                    ),
                  ),
                  SizedBox(width: 8),
                  Text("Bot is typing...", style: TextStyle(color: Colors.white, fontSize: 16)),
                ],
              )
                  : message.hasButtons
                  ? _buildEscalationButtons() // Display buttons inside the message container
                  : Text(message.text, style: TextStyle(color: Colors.white, fontSize: 16)),
            ),
          ),
          if (isUser) SizedBox(width: 10),
          if (isUser)
            CircleAvatar(
              backgroundColor: Colors.blueAccent,
              child: Icon(Icons.person, color: Colors.white),
            ),
        ],
      ),
    );
  }

  Widget _buildInputArea() {
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.grey[900],
          borderRadius: BorderRadius.circular(30),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.3),
              blurRadius: 4,
              offset: Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          children: [
            SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _controller,
                focusNode: _focusNode,
                decoration: InputDecoration(
                  hintText: "Type a message...",
                  hintStyle: TextStyle(color: Colors.grey[500]),
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 15),
                ),
                style: TextStyle(color: Colors.white),
                onSubmitted: (value) {
                  _sendMessage(); // Send the message when Enter is pressed
                },
              ),
            ),
            IconButton(
              icon: Icon(Icons.send, color: Colors.blueAccent),
              onPressed: _sendMessage,
            ),
          ],
        ),
      ),
    );
  }

  @override
  @override
  Widget build(BuildContext context) {
    if (_showWelcomeMessage && _messages.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: Text("Hotel Chatbot Assistant")),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                "How can I help you today? 😊",
                style: TextStyle(color: Colors.grey[400], fontSize: 18, fontWeight: FontWeight.w500),
                textAlign: TextAlign.center,
              ),
              SizedBox(height: 20),
              _buildInputArea(),
              // Add the button here for adding a receptionist
              ElevatedButton(
                onPressed: () {
                  // Trigger the function to add receptionist
                },
                child: Text("Add Receptionist to Firestore"),
              ),
              SizedBox(height: 20), // Add spacing between button and other UI components
            ],
          ),
        ),
      );
    } else {
      return Scaffold(
        appBar: AppBar(title: Text("Hotel Chatbot Assistant")),
        body: Column(
          children: [
            Expanded(
              child: ListView.builder(
                controller: _scrollController,
                reverse: false,
                itemCount: _messages.length,
                itemBuilder: (context, index) => _buildMessage(_messages[index], index),
              ),
            ),
            _buildInputArea(),
            // Optionally, you can add the button here too if you want it to show in this state
            ElevatedButton(
              onPressed: () {
                // Trigger the function to add receptionist
              },
              child: Text("Add Receptionist to Firestore"),
            ),
            SizedBox(height: 20), // Add spacing between button and other UI components
          ],
        ),
      );
    }
  }
}

class ChatMessage {
  final String text;
  final bool isUser;
  final bool isTemporary;
  final bool hasButtons; // Add this property to track if the message has buttons

  ChatMessage({required this.text, required this.isUser, this.isTemporary = false, this.hasButtons = false});
}

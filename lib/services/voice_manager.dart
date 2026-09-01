import 'package:flutter_tts/flutter_tts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

typedef OnResultCallback = Function(String recognizedText);
typedef OnErrorCallback = Function(String errorMessage);
typedef OnListeningStateChange = Function(bool isListening);

class VoiceManager {
  static final VoiceManager _instance = VoiceManager._internal();

  late stt.SpeechToText _speechToText;
  late FlutterTts _flutterTts;

  bool _isInitialized = false;
  bool _isListening = false;
  String _recognizedText = '';

  OnResultCallback? _onResult;
  OnErrorCallback? _onError;
  OnListeningStateChange? _onListeningStateChange;

  factory VoiceManager() {
    return _instance;
  }

  VoiceManager._internal();

  // Getters
  bool get isInitialized => _isInitialized;
  bool get isListening => _isListening;
  String get recognizedText => _recognizedText;

  /// Initialize VoiceManager - call this on app startup
  Future<bool> initialize() async {
    try {
      if (_isInitialized) return true;

      _speechToText = stt.SpeechToText();
      _flutterTts = FlutterTts();

      // Initialize speech_to_text
      bool available = await _speechToText.initialize(
        onError: (error) {
          _handleError('Speech error: $error');
        },
        onStatus: (status) {
          _handleStatus(status);
        },
      );

      if (!available) {
        _handleError('Speech recognition not available');
        return false;
      }

      // Initialize TTS
      await _flutterTts.setLanguage("en-US");
      await _flutterTts.setPitch(1.0);
      await _flutterTts.setSpeechRate(0.5);

      // Request microphone permission
      final status = await Permission.microphone.request();
      if (!status.isGranted) {
        _handleError('Microphone permission denied');
        return false;
      }

      _isInitialized = true;
      return true;
    } catch (e) {
      _handleError('Initialization error: $e');
      return false;
    }
  }

  /// Set callbacks for voice events
  void setCallbacks({
    OnResultCallback? onResult,
    OnErrorCallback? onError,
    OnListeningStateChange? onListeningStateChange,
  }) {
    _onResult = onResult;
    _onError = onError;
    _onListeningStateChange = onListeningStateChange;
  }

  /// Speak greeting on app open
  Future<void> speakGreeting(String userName) async {
    try {
      String greeting = "Namaste! $userName";
      await _flutterTts.speak(greeting);
    } catch (e) {
      _handleError('TTS error: $e');
    }
  }

  /// Start quiet listening for wake word (background, no notifications)
  Future<void> startQuietListeningForWakeWord() async {
    if (!_isInitialized) {
      _handleError('VoiceManager not initialized');
      return;
    }

    try {
      _isListening = true;
      _recognizedText = '';

      // Listen continuously with longer timeout - quiet mode
      await _speechToText.listen(
        onResult: _handleWakeWordResult,
        listenFor: const Duration(seconds: 30),
        pauseFor: const Duration(seconds: 1),
        localeId: 'en_US',
      );
    } catch (e) {
      _handleError('Wake word listening error: $e');
      _isListening = false;
      // Restart quiet listening automatically on error
      
    }
  }

  /// Start listening for wake word (legacy - maps to quiet listening)
  Future<void> startListeningForWakeWord() async {
    await startQuietListeningForWakeWord();
  }

  /// Start active listening for command (after wake word detected)
  Future<void> startListeningForCommand() async {
    if (!_isInitialized) {
      _handleError('VoiceManager not initialized');
      return;
    }

    try {
      _isListening = true;
      _onListeningStateChange?.call(true); // Notify UI that actively listening
      _recognizedText = '';

      // Speak prompt for command
      await _flutterTts.speak("What would you like to do?");

      await Future.delayed(const Duration(milliseconds: 500));

      // Listen for command
      await _speechToText.listen(
        onResult: _handleCommandResult,
        listenFor: const Duration(seconds: 15),
        pauseFor: const Duration(seconds: 3),
        localeId: 'en_US',
      );
    } catch (e) {
      _handleError('Command listening error: $e');
      _isListening = false;
      _onListeningStateChange?.call(false);
      // Fallback to quiet listening
      Future.delayed(const Duration(milliseconds: 500), () {
        startQuietListeningForWakeWord();
      });
    }
  }

  /// Stop listening
  Future<void> stopListening() async {
    try {
      await _speechToText.stop();
      _isListening = false;
      _onListeningStateChange?.call(false);
    } catch (e) {
      _handleError('Stop listening error: $e');
    }
  }

  /// Handle wake word recognition result
  void _handleWakeWordResult(result) {
    _recognizedText = result.recognizedWords.toLowerCase();

    if (result.finalResult) {
      if (_isWakeWordDetected(_recognizedText)) {
        // Wake word detected! Go into active listening mode
        stopListening();
        _onResult?.call('wake_word_detected');
        // Start active listening for command with sound/feedback
        Future.delayed(const Duration(milliseconds: 500), () {
          startListeningForCommand();
        });
      } else {
        // Wake word not detected, keep listening quietly
        stopListening();
        
      }
    }
  }

  /// Handle command recognition result
  void _handleCommandResult(result) {
    _recognizedText = result.recognizedWords.toLowerCase();

    if (result.finalResult) {
      // Parse the command
      final parsedCommand = _parseCommand(_recognizedText);

      if (parsedCommand != null) {
        _onResult?.call(_recognizedText);
      } else {
        _handleError('Could not understand command');
      }
      _isListening = false;
    _onListeningStateChange?.call(false);
      
    }
  }

  /// Detect if wake word is present in recognized text
  bool _isWakeWordDetected(String text) {
    // Wake word: "Hey Sahayta"
    return text.contains('hey sahayta') ||
        text.contains('hey sahayata') ||
        text.contains('hi sahayta') ||
        text.contains('hello sahayta');
  }

  /// Parse command and extract data
  /// Returns null if unable to parse
  Map<String, String>? _parseCommand(String text) {
    try {
      // Login pattern: "login using username xyz password abc"
      if (_isLoginCommand(text)) {
        final credentials = _extractLoginCredentials(text);
        if (credentials != null) {
          return credentials;
        }
      }

      // Search pattern: "search for video xyz"
      if (_isSearchCommand(text)) {
        return {'command': 'search', 'query': _extractSearchQuery(text)};
      }

      // Convert pattern: "convert my last video to 4k"
      if (_isConvertCommand(text)) {
        return {'command': 'convert', 'target': _extractConvertTarget(text)};
      }

      return null;
    } catch (e) {
      _handleError('Command parsing error: $e');
      return null;
    }
  }

  /// Check if text contains login command
  bool _isLoginCommand(String text) {
  return text.contains('login') ||
      text.contains('sign in') ||
      text.contains('log in') ||
      (text.contains('username') && text.contains('password'));
}

  /// Extract login credentials from text
  /// Pattern: "login using username demo password pass123"
  Map<String, String>? _extractLoginCredentials(String text) {
    try {
      // Simple extraction - looking for keywords
      String username = '';
      String password = '';

      // Find username after "username" keyword
      if (text.contains('username')) {
        final parts = text.split('username');
        if (parts.length > 1) {
          final afterUsername = parts[1].trim();
          // Get first word after username
          username = afterUsername.split(' ').first;
        }
      }

      // Find password after "password" keyword
      if (text.contains('password')) {
        final parts = text.split('password');
        if (parts.length > 1) {
          final afterPassword = parts[1].trim();
          // Get first word after password
          password = afterPassword.split(' ').first;
        }
      }

      if (username.isNotEmpty && password.isNotEmpty) {
        return {
          'command': 'login',
          'username': username,
          'password': password,
        };
      }

      return null;
    } catch (e) {
      return null;
    }
  }

  /// Check if text contains search command
  bool _isSearchCommand(String text) {
    return text.contains('search') ||
        text.contains('find') ||
        text.contains('look for');
  }

  /// Extract search query
  String _extractSearchQuery(String text) {
    try {
      if (text.contains('search for')) {
        return text.split('search for').last.trim();
      } else if (text.contains('find')) {
        return text.split('find').last.trim();
      }
      return text;
    } catch (e) {
      return text;
    }
  }

  /// Check if text contains convert command
  bool _isConvertCommand(String text) {
    return text.contains('convert') && (text.contains('4k') || text.contains('hd'));
  }

  /// Extract convert target
  String _extractConvertTarget(String text) {
    try {
      if (text.contains('4k')) return '4k';
      if (text.contains('hd')) return 'hd';
      return '4k'; // default
    } catch (e) {
      return '4k';
    }
  }

  /// Handle speech-to-text errors
  void _handleError(String error) {
    _onError?.call(error);
  }

  /// Handle speech-to-text status changes
  void _handleStatus(String status) {
    // Handle status if needed (e.g., "listening", "notListening")
  }

  /// Speak text using TTS
  Future<void> speak(String text) async {
    try {
      await _flutterTts.speak(text);
    } catch (e) {
      _handleError('TTS error: $e');
    }
  }

  /// Dispose resources
  Future<void> dispose() async {
    try {
      await _speechToText.stop();
      await _flutterTts.stop();
    } catch (e) {
      _handleError('Dispose error: $e');
    }
  }
}
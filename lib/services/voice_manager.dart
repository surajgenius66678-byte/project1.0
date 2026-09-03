import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_tts/flutter_tts.dart';
import 'package:open_wake_word/open_wake_word.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

typedef OnResultCallback = Function(String recognizedText);
typedef OnErrorCallback = Function(String errorMessage);
typedef OnListeningStateChange = Function(bool isListening);

class VoiceManager {
  static final VoiceManager _instance = VoiceManager._internal();

  // ============================================================
  // EXISTING VOICE COMPONENTS
  // ============================================================

  late stt.SpeechToText _speechToText;
  late FlutterTts _flutterTts;

  // ============================================================
  // WAKE WORD COMPONENTS
  // ============================================================

  final AudioRecorder _audioRecorder = AudioRecorder();

  StreamSubscription<Uint8List>? _wakeWordAudioSubscription;

  bool _wakeWordInitialized = false;
  bool _wakeWordListening = false;

  // Prevent multiple detections while transitioning
  bool _wakeWordHandling = false;

  // ============================================================
  // GENERAL STATE
  // ============================================================

  bool _isInitialized = false;
  bool _isListening = false;
  String _recognizedText = '';

  OnResultCallback? _onResult;
  OnErrorCallback? _onError;
  OnListeningStateChange? _onListeningStateChange;

  // ============================================================
  // SINGLETON
  // ============================================================

  factory VoiceManager() {
    return _instance;
  }

  VoiceManager._internal();

  // ============================================================
  // GETTERS
  // ============================================================

  bool get isInitialized => _isInitialized;
  bool get isListening => _isListening;
  bool get isWakeWordListening => _wakeWordListening;
  String get recognizedText => _recognizedText;

  // ============================================================
  // INITIALIZATION
  // ============================================================

  /// Initialize VoiceManager.
  ///
  /// This initializes:
  /// - Speech-to-text
  /// - Text-to-speech
  /// - Microphone permission
  /// - Hey Horus wake-word engine
  Future<bool> initialize() async {
    try {
      if (_isInitialized) {
        return true;
      }

      // ----------------------------------------------------------
      // Speech-to-text
      // ----------------------------------------------------------

      _speechToText = stt.SpeechToText();

      // ----------------------------------------------------------
      // Text-to-speech
      // ----------------------------------------------------------

      _flutterTts = FlutterTts();

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

      await _flutterTts.setLanguage("en-US");
      await _flutterTts.setPitch(1.0);
      await _flutterTts.setSpeechRate(0.5);

      // ----------------------------------------------------------
      // Microphone permission
      // ----------------------------------------------------------

      final status = await Permission.microphone.request();

      if (!status.isGranted) {
        _handleError('Microphone permission denied');
        return false;
      }

      // ----------------------------------------------------------
      // Hey Horus wake-word engine
      // ----------------------------------------------------------

      final wakeWordReady = await initializeWakeWord();

      if (!wakeWordReady) {
        _handleError('Hey Horus wake-word engine initialization failed');
        return false;
      }

      _isInitialized = true;

      return true;
    } catch (e) {
      _handleError('Initialization error: $e');
      return false;
    }
  }

  // ============================================================
  // WAKE WORD INITIALIZATION
  // ============================================================

  /// Initialize the OpenWakeWord engine.
  Future<bool> initializeWakeWord() async {
    try {
      if (_wakeWordInitialized) {
        return true;
      }

      final success = await OpenWakeWord.init(
        melModelAssetPath: 'assets/models/melspectrogram.onnx',
        embModelAssetPath: 'assets/models/embedding_model.onnx',
        wwModelAssetPaths: [
          'assets/models/hey_horus.onnx',
        ],
      );

      _wakeWordInitialized = success;

      if (!success) {
        _handleError('Could not initialize Hey Horus model');
      }

      return success;
    } catch (e) {
      _handleError('Wake-word initialization error: $e');
      return false;
    }
  }

  // ============================================================
  // CALLBACKS
  // ============================================================

  void setCallbacks({
    OnResultCallback? onResult,
    OnErrorCallback? onError,
    OnListeningStateChange? onListeningStateChange,
  }) {
    _onResult = onResult;
    _onError = onError;
    _onListeningStateChange = onListeningStateChange;
  }

  // ============================================================
  // TTS
  // ============================================================

  /// Speak greeting on app open.
  Future<void> speakGreeting(String userName) async {
    try {
      final greeting = "Namaste! $userName";
      await _flutterTts.speak(greeting);
    } catch (e) {
      _handleError('TTS error: $e');
    }
  }

  /// Speak arbitrary text.
  Future<void> speak(String text) async {
    try {
      await _flutterTts.speak(text);
    } catch (e) {
      _handleError('TTS error: $e');
    }
  }

  // ============================================================
  // WAKE WORD LISTENING
  // ============================================================

  /// Start continuous Hey Horus detection.
  ///
  /// Microphone:
  /// 16 kHz
  /// Mono
  /// PCM16
  ///
  /// Audio is continuously passed to OpenWakeWord.
  Future<void> startQuietListeningForWakeWord() async {
    if (!_isInitialized) {
      _handleError('VoiceManager not initialized');
      return;
    }

    try {
      if (_wakeWordListening) {
        return;
      }

      if (!await _audioRecorder.hasPermission()) {
        _handleError('Microphone permission denied');
        return;
      }

      if (!await initializeWakeWord()) {
        return;
      }

      final stream = await _audioRecorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
        ),
      );

      _wakeWordListening = true;
      _wakeWordHandling = false;

      _wakeWordAudioSubscription = stream.listen(
        (Uint8List bytes) {
          if (!_wakeWordListening || _wakeWordHandling) {
            return;
          }

          try {
            // record provides PCM16 bytes.
            // OpenWakeWord expects Int16List.
            final int16Audio = _bytesToInt16(bytes);

            if (int16Audio.isEmpty) {
              return;
            }

            OpenWakeWord.processAudio(int16Audio);

            final probability = OpenWakeWord.getProbability();

            // Useful while testing.
            print(
              'Hey Horus probability: '
              '${probability.toStringAsFixed(4)}',
            );

            if (OpenWakeWord.isActivated()) {
              _handleWakeWordDetected(probability);
            }
          } catch (e) {
            _handleError('Wake-word processing error: $e');
          }
        },
        onError: (error) {
          _handleError(
            'Wake-word audio stream error: $error',
          );

          _stopWakeWordEngine();
        },
        cancelOnError: false,
      );
    } catch (e) {
      _handleError('Wake-word listening error: $e');
      await _stopWakeWordEngine();
    }
  }

  // ============================================================
  // PCM16 CONVERSION
  // ============================================================

  /// Convert little-endian PCM16 bytes to Int16List.
  Int16List _bytesToInt16(Uint8List bytes) {
    final sampleCount = bytes.length ~/ 2;

    final result = Int16List(sampleCount);

    for (int i = 0; i < sampleCount; i++) {
      final low = bytes[i * 2];
      final high = bytes[i * 2 + 1];

      int value = low | (high << 8);

      // Convert unsigned 16-bit representation
      // into signed 16-bit PCM.
      if (value >= 0x8000) {
        value -= 0x10000;
      }

      result[i] = value;
    }

    return result;
  }

  // ============================================================
  // WAKE WORD DETECTED
  // ============================================================

  Future<void> _handleWakeWordDetected(double probability) async {
  if (_wakeWordHandling) {
    return;
  }

  _wakeWordHandling = true;

  print(
    'HEY HORUS DETECTED! '
    'score=${probability.toStringAsFixed(4)}',
  );

  try {
    // Stop wake-word listening first
    await _stopWakeWordEngine();

    // Tell the app that the wake word was detected
    _onResult?.call('wake_word_detected');

    // Say hello
    await _flutterTts.speak("Hello");

    // Give TTS/microphone a moment to transition
    await Future.delayed(
      const Duration(milliseconds: 700),
    );

    // Start listening for the user's command
    await startListeningForCommand();
  } catch (e) {
    _handleError(
      'Wake-word activation error: $e',
    );
  } finally {
    _wakeWordHandling = false;
  }
}

  // ============================================================
  // STOP WAKE WORD ENGINE
  // ============================================================

  Future<void> _stopWakeWordEngine() async {
    try {
      await _wakeWordAudioSubscription?.cancel();
      _wakeWordAudioSubscription = null;

      if (_wakeWordListening) {
        await _audioRecorder.stop();
      }

      _wakeWordListening = false;
    } catch (e) {
      _handleError(
        'Stop wake-word engine error: $e',
      );
    }
  }

  // ============================================================
  // LEGACY METHOD
  // ============================================================

  /// Kept for compatibility with existing code.
  Future<void> startListeningForWakeWord() async {
    await startQuietListeningForWakeWord();
  }

  // ============================================================
  // COMMAND LISTENING
  // ============================================================

  /// Start active speech recognition after Hey Horus is detected.
  Future<void> startListeningForCommand() async {
    if (!_isInitialized) {
      _handleError('VoiceManager not initialized');
      return;
    }

    try {
      _isListening = true;
      _recognizedText = '';

      _onListeningStateChange?.call(true);

      // Prompt the user.
      await _flutterTts.speak(
        "What would you like to do?",
      );

      await Future.delayed(
        const Duration(milliseconds: 500),
      );

      // Start command recognition.
      await _speechToText.listen(
        onResult: _handleCommandResult,
        listenFor: const Duration(seconds: 15),
        pauseFor: const Duration(seconds: 3),
        localeId: 'en_US',
      );
    } catch (e) {
      _handleError(
        'Command listening error: $e',
      );

      _isListening = false;
      _onListeningStateChange?.call(false);

      await Future.delayed(
        const Duration(milliseconds: 500),
      );

      // Return to wake-word listening.
      await startQuietListeningForWakeWord();
    }
  }

  // ============================================================
  // STOP LISTENING
  // ============================================================

  Future<void> stopListening() async {
    try {
      await _speechToText.stop();

      await _stopWakeWordEngine();

      _isListening = false;

      _onListeningStateChange?.call(false);
    } catch (e) {
      _handleError(
        'Stop listening error: $e',
      );
    }
  }

  // ============================================================
  // COMMAND RESULT
  // ============================================================

  void _handleCommandResult(result) {
    _recognizedText =
        result.recognizedWords.toLowerCase();

    print(
      'Recognized command: $_recognizedText',
    );

    if (result.finalResult) {
      final parsedCommand =
          _parseCommand(_recognizedText);

      if (parsedCommand != null) {
        _onResult?.call(_recognizedText);
      } else {
        _handleError(
          'Could not understand command',
        );
      }

      _isListening = false;

      _onListeningStateChange?.call(false);

      // Return to wake-word mode after command.
      Future.delayed(
        const Duration(milliseconds: 500),
        () {
          startQuietListeningForWakeWord();
        },
      );
    }
  }

  // ============================================================
  // COMMAND PARSER
  // ============================================================

  Map<String, String>? _parseCommand(String text) {
    try {
      // ----------------------------------------------------------
      // Login
      // ----------------------------------------------------------

      if (_isLoginCommand(text)) {
        final credentials =
            _extractLoginCredentials(text);

        if (credentials != null) {
          return credentials;
        }
      }

      // ----------------------------------------------------------
      // Search
      // ----------------------------------------------------------

      if (_isSearchCommand(text)) {
        return {
          'command': 'search',
          'query': _extractSearchQuery(text),
        };
      }

      // ----------------------------------------------------------
      // Convert
      // ----------------------------------------------------------

      if (_isConvertCommand(text)) {
        return {
          'command': 'convert',
          'target': _extractConvertTarget(text),
        };
      }

      return null;
    } catch (e) {
      _handleError(
        'Command parsing error: $e',
      );

      return null;
    }
  }

  // ============================================================
  // LOGIN COMMAND
  // ============================================================

  bool _isLoginCommand(String text) {
    return text.contains('login') ||
        text.contains('sign in') ||
        text.contains('log in') ||
        (text.contains('username') &&
            text.contains('password'));
  }

  Map<String, String>? _extractLoginCredentials(
    String text,
  ) {
    try {
      String username = '';
      String password = '';

      if (text.contains('username')) {
        final parts = text.split('username');

        if (parts.length > 1) {
          final afterUsername =
              parts[1].trim();

          username =
              afterUsername.split(' ').first;
        }
      }

      if (text.contains('password')) {
        final parts = text.split('password');

        if (parts.length > 1) {
          final afterPassword =
              parts[1].trim();

          password =
              afterPassword.split(' ').first;
        }
      }

      if (username.isNotEmpty &&
          password.isNotEmpty) {
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

  // ============================================================
  // SEARCH COMMAND
  // ============================================================

  bool _isSearchCommand(String text) {
    return text.contains('search') ||
        text.contains('find') ||
        text.contains('look for');
  }

  String _extractSearchQuery(String text) {
    try {
      if (text.contains('search for')) {
        return text
            .split('search for')
            .last
            .trim();
      }

      if (text.contains('find')) {
        return text
            .split('find')
            .last
            .trim();
      }

      return text;
    } catch (e) {
      return text;
    }
  }

  // ============================================================
  // CONVERT COMMAND
  // ============================================================

  bool _isConvertCommand(String text) {
    return text.contains('convert') &&
        (text.contains('4k') ||
            text.contains('hd'));
  }

  String _extractConvertTarget(String text) {
    try {
      if (text.contains('4k')) {
        return '4k';
      }

      if (text.contains('hd')) {
        return 'hd';
      }

      return '4k';
    } catch (e) {
      return '4k';
    }
  }

  // ============================================================
  // ERRORS
  // ============================================================

  void _handleError(String error) {
    print('VoiceManager error: $error');
    _onError?.call(error);
  }

  // ============================================================
  // SPEECH STATUS
  // ============================================================

  void _handleStatus(String status) {
    print('Speech status: $status');
  }

  // ============================================================
  // DISPOSE
  // ============================================================

  Future<void> dispose() async {
    try {
      await _speechToText.stop();

      await _stopWakeWordEngine();

      await _flutterTts.stop();

      _audioRecorder.dispose();

      if (_wakeWordInitialized) {
        OpenWakeWord.destroy();
        _wakeWordInitialized = false;
      }

      _isListening = false;
      _isInitialized = false;
    } catch (e) {
      _handleError(
        'Dispose error: $e',
      );
    }
  }
}
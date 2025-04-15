import 'dart:io';
import 'dart:async'; // Timer için eklendi
import 'dart:typed_data'; // Uint8List için eklendi
import 'package:wakelock_plus/wakelock_plus.dart'; // YENİSİNİ EKLE
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart'
    as img; // image paketini img ön ekiyle kullanacağız

late List<CameraDescription> _cameras;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    _cameras = await availableCameras();
  } on CameraException catch (e) {
    print(
      'Error initializing cameras: ${e.code}\nError Message: ${e.description}',
    );
    _cameras = [];
  }
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Akıllı Göz',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        visualDensity: VisualDensity.adaptivePlatformDensity,
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  CameraController? _cameraController;
  bool _isCameraInitialized = false;
  bool _isPermissionGranted = false;
  Interpreter? _interpreter;
  List<String> _labels = []; // Etiket listesi
  bool _isProcessing =
      false; // Aynı anda birden fazla kare işlemeyi önlemek için
  Timer? _processingTimer; // Belirli aralıklarla işlem yapmak için (opsiyonel)

  // Modelin giriş boyutları (MobileNetV1 224x224 bekler)
  final int _inputSize = 224;
  // Modelin quantize edilmiş olup olmadığı (bizimki quantize idi)
  final bool _isQuantized = true;

  String _resultText = "Nesne bekleniyor...";
  String _bluetoothStatus = "Bluetooth: Bağlı Değil";

  @override
  void initState() {
    super.initState();
    // Önce izinleri iste, sonra modeli yükle ve kamerayı başlat
    _requestPermissionsAndInitialize();
    // Ekranın kapanmasını engelle
    WakelockPlus.enable(); // Sınıf adı WakelockPlus oldu
    print("WakelockPlus etkinleştirildi.");
  }

  @override
  void dispose() {
    _processingTimer?.cancel(); // Zamanlayıcıyı iptal et
    _cameraController?.stopImageStream(); // Görüntü akışını durdur
    _cameraController?.dispose();
    _interpreter?.close();
    // Ekranın kapanmasına tekrar izin ver
    WakelockPlus.disable(); // Sınıf adı WakelockPlus oldu
    print("WakelockPlus devre dışı bırakıldı.");
    // ... (dispose içindeki diğer kodlar) ...
    super.dispose();
  }

  Future<void> _requestPermissionsAndInitialize() async {
    var cameraStatus = await Permission.camera.request();
    setState(() {
      _isPermissionGranted = cameraStatus.isGranted;
    });

    if (_isPermissionGranted) {
      // İzin verildiyse ÖNCE modeli yükle
      await _loadModel();
      // SONRA kamerayı başlat
      _initializeCamera();
    } else {
      print("Kamera izni verilmedi.");
      setState(() {
        _resultText = "Kamera izni gerekli!";
      });
    }
  }

  // TFLite modelini ve etiketleri yükleyen fonksiyon
  Future<void> _loadModel() async {
    try {
      // Interpreter'ı yükle
      _interpreter = await Interpreter.fromAsset(
        'assets/model.tflite',
      ); // assets klasöründeki dosya adı

      // Etiketleri yükle
      final labelsData = await rootBundle.loadString(
        'assets/labels.txt',
      ); // assets klasöründeki dosya adı
      _labels =
          labelsData
              .split('\n')
              .map((label) => label.trim())
              .where((label) => label.isNotEmpty)
              .toList();

      print('Model ve etiketler başarıyla yüklendi.');
      print('Toplam etiket sayısı: ${_labels.length}');
    } catch (e) {
      print('Model veya etiketler yüklenirken hata oluştu: $e');
      setState(() {
        _resultText = "Model yüklenemedi!";
      });
    }
  }

  void _initializeCamera() {
    if (_cameras.isEmpty || _isCameraInitialized || _interpreter == null)
      return; // Interpreter yüklenmediyse başlatma

    final cameraDescription = _cameras[0];
    _cameraController = CameraController(
      cameraDescription,
      ResolutionPreset.low,
      enableAudio: false,
      imageFormatGroup:
          Platform.isAndroid
              ? ImageFormatGroup
                  .yuv420 // Android için YUV
              : ImageFormatGroup.bgra8888, // iOS için BGRA
    );

    _cameraController!
        .initialize()
        .then((_) {
          if (!mounted) return;
          setState(() {
            _isCameraInitialized = true;
            _resultText = "Kameraya bir nesne gösterin";
          });
          // Kamera başlatıldıktan SONRA görüntü akışını başlat
          _startImageStream();
        })
        .catchError((Object e) {
          if (e is CameraException) {
            print(
              'Kamera başlatılırken hata: ${e.code}\nMesaj: ${e.description}',
            );
            setState(() {
              _resultText = "Kamera başlatılamadı: ${e.code}";
              _isCameraInitialized = false;
            });
          }
        });
  }

  // Görüntü akışını başlatan fonksiyon (ESKİ VE BASİT HALİ)
  void _startImageStream() {
    _cameraController?.startImageStream((CameraImage cameraImage) {
      if (_isProcessing || _interpreter == null) return;
      _isProcessing = true;
      _processCameraImage(cameraImage); // Görüntüyü işle
    });
    print("Görüntü akışı başlatıldı.");
  }

  // Kameradan gelen görüntüyü işleyen fonksiyon
  Future<void> _processCameraImage(CameraImage cameraImage) async {
    if (_interpreter == null || !_isCameraInitialized)
      return; // Kamera kontrolü eklendi

    try {
      // Görüntüyü TFLite'ın beklediği Uint8List formatına dönüştür
      var inputBytes = _convertCameraImage(cameraImage); // Değişken adı değişti

      if (inputBytes != null) {
        // Giriş ve çıkış tensörlerini hazırla
        // Giriş: inputBytes zaten Uint8List [1, 224, 224, 3] şeklinde olmalı (quantize için)
        // Çıkış şekli [1, EtiketSayısı]
        var output = List.filled(
          1 * _labels.length,
          0,
        ).reshape([1, _labels.length]);

        // Modeli çalıştır
        // Not: Eğer model Float32 bekliyorsa, inputBytes'ı Float32List'e çevirip normalize etmek gerekir.
        _interpreter!.run(inputBytes, output);

        // Çıktıyı yorumla
        var results = output[0] as List<num>;

        // En yüksek olasılıklı sonucu bul
        int bestIndex = -1;
        double highestProb = -1.0;
        for (int i = 0; i < results.length; i++) {
          double prob =
              _isQuantized
                  ? results[i].toDouble() / 255.0
                  : results[i].toDouble();
          if (prob > highestProb) {
            highestProb = prob;
            bestIndex = i;
          }
        }

        // Sonucu güncelle
        if (bestIndex != -1 && highestProb > 0.6) {
          // Eşik değerini biraz artırdım (örn. %60)
          if (mounted) {
            // Widget hala ağaçta mı kontrol et
            setState(() {
              _resultText =
                  "${_labels[bestIndex]} (${(highestProb * 100).toStringAsFixed(1)}%)";
              // ---- BURAYA BLUETOOTH KODU GELECEK ----
              // sendBluetoothCommand(_labels[bestIndex]);
              // --------------------------------------
            });
          }
        }
        // else { // İsteğe bağlı: düşük olasılıkta ne yapılacağı
        //   if(mounted) {
        //     setState(() { _resultText = "Tanımlanamadı"; });
        //   }
        // }
      }
    } catch (e, stacktrace) {
      // Stacktrace'i de yakala
      print("Görüntü işlenirken hata: $e");
      print("Stacktrace: $stacktrace"); // Hatanın nerede olduğunu görmek için
    } finally {
      // İşlemin bittiğini işaretle
      _isProcessing = false;
      // ---- PERFORMANS İÇİN GECİKME ----
      // Bir sonraki karenin hemen işlenmemesi için kısa bir bekleme ekle
      // (await anahtar kelimesini unutmayın)
      await Future.delayed(
        const Duration(milliseconds: 50),
      ); // 100ms bekle (bu süreyi artırıp azaltarak deneyebilirsiniz)
    }
  }

  // CameraImage'ı TFLite için uygun Uint8List formatına (224x224 RGB) dönüştüren fonksiyon
  Uint8List? _convertCameraImage(CameraImage cameraImage) {
    img.Image? image;

    if (Platform.isAndroid) {
      if (cameraImage.format.group == ImageFormatGroup.yuv420) {
        image = _convertYUV420(cameraImage);
      } else {
        print("Beklenmeyen Android formatı: ${cameraImage.format.group}");
        return null;
      }
    } else if (Platform.isIOS) {
      if (cameraImage.format.group == ImageFormatGroup.bgra8888) {
        image = _convertBGRA8888(cameraImage);
      } else {
        print("Beklenmeyen iOS formatı: ${cameraImage.format.group}");
        return null;
      }
    } else {
      return null;
    }

    if (image == null) return null;

    var resizedImage = img.copyResize(
      image,
      width: _inputSize,
      height: _inputSize,
    );

    // Manuel Döngü (Daha Güvenilir)
    var imageBytes = Uint8List(_inputSize * _inputSize * 3);
    int pixelIndex = 0;
    for (int y = 0; y < _inputSize; y++) {
      for (int x = 0; x < _inputSize; x++) {
        var pixel = resizedImage.getPixel(x, y);
        // ---- DÜZELTME ----
        imageBytes[pixelIndex++] = img.getRed(pixel).toInt(); // Kırmızı
        imageBytes[pixelIndex++] = img.getGreen(pixel).toInt(); // Yeşil
        imageBytes[pixelIndex++] = img.getBlue(pixel).toInt(); // Mavi
        // -----------------
      }
    }
    return imageBytes;
  }

  // YUV420 (Android) formatını RGB Image nesnesine dönüştürür
  img.Image _convertYUV420(CameraImage image) {
    // ... (Fonksiyonun başlangıcı ve YUV okuma kısmı aynı)
    final int width = image.width;
    final int height = image.height;
    final int uvRowStride = image.planes[1].bytesPerRow;
    final int uvPixelStride = image.planes[1].bytesPerPixel!;
    final yPlane = image.planes[0].bytes;
    final uPlane = image.planes[1].bytes;
    final vPlane = image.planes[2].bytes;

    img.Image rgbImage = img.Image(width, height);

    int yp = 0;
    for (int y = 0; y < height; y++) {
      int uvp = (y >> 1) * uvRowStride;
      int u = 0; // Initialize u and v for safety
      int v = 0;
      for (int x = 0; x < width; x++, yp++) {
        int uvIndex = uvp + (x >> 1) * uvPixelStride;

        // Check plane lengths to avoid out of bounds errors if possible
        if (uvIndex >= uPlane.length || uvIndex >= vPlane.length) continue;

        // Assuming NV21 or similar where U/V might be interleaved or in separate planes
        // This part is highly dependent on the exact YUV format variant.
        // Let's stick to a common approximation assuming separate planes or simple fetch
        try {
          // Use plane indices 1 and 2 for U and V
          u = image.planes[1].bytes[uvIndex];
          v = image.planes[2].bytes[uvIndex];
        } catch (e) {
          // Handle potential index out of bounds, especially at image edges
          print("Error accessing UV planes at index $uvIndex: $e");
          continue; // Skip this pixel if UV data is inaccessible
        }

        int yValue = yPlane[yp] & 0xFF;

        // YUV to RGB conversion
        int r = (yValue + (1.370705 * (v - 128))).toInt().clamp(0, 255);
        int g = (yValue - (0.337633 * (u - 128)) - (0.698001 * (v - 128)))
            .toInt()
            .clamp(0, 255);
        int b = (yValue + (1.732446 * (u - 128))).toInt().clamp(0, 255);

        // ---- DÜZELTME ----
        // setPixelRgb yerine setPixelRgba kullan (alpha = 255)
        rgbImage.setPixelRgba(x, y, r, g, b, 255);
        // -----------------
      }
    }
    return rgbImage;
  }

  // BGRA8888 (iOS) formatını RGB Image nesnesine dönüştürür
  img.Image _convertBGRA8888(CameraImage image) {
    // ---- DÜZELTME ----
    // İsimli parametreler yerine pozisyonel parametreler kullan
    return img.Image.fromBytes(
      image.width, // 1. Argüman: width
      image.height, // 2. Argüman: height
      image.planes[0].bytes, // 3. Argüman: bytes (Uint8List List<int>'dir)
      // format: img.Format.bgra, // Format genellikle otomatik algılanır, gerekirse eklenebilir
      // rowStride: image.planes[0].bytesPerRow, // Gerekirse eklenebilir
    );
    // -----------------
  }

  // ---- BLUETOOTH FONKSİYONU (ŞİMDİLİK BOŞ) ----
  // void sendBluetoothCommand(String label) {
  //   // Tespit edilen etikete göre komut belirle
  //   String command = "";
  //   if (label.contains("bottle") || label.contains("plastic bag")) {
  //      command = "SORT:PLASTIC";
  //   } else if (label.contains("can") || label.contains("foil")) { // Alüminyum folyo vb.
  //      command = "SORT:METAL";
  //   } else if (label.contains("paper") || label.contains("carton") || label.contains("envelope")) {
  //      command = "SORT:PAPER";
  //   } else if (label.contains("glass")) { // Model glass bottle vb. tanıyorsa
  //      command = "SORT:GLASS";
  //   } // ... diğer eşleştirmeler ...
  //
  //   if (command.isNotEmpty) {
  //     // Bluetooth üzerinden komutu gönder (bluetooth paketi eklenince implemente edilecek)
  //     print("Bluetooth komutu gönderiliyor: $command");
  //     // _bluetoothConnection?.output.add(ascii.encode('$command\r\n')); // Örnek
  //   }
  // }
  // -------------------------------------------

  @override
  Widget build(BuildContext context) {
    if (!_isPermissionGranted ||
        !_isCameraInitialized ||
        _cameraController == null ||
        _interpreter == null) {
      // Interpreter kontrolü eklendi
      return Scaffold(
        appBar: AppBar(title: const Text('Akıllı Göz')),
        body: Center(
          child:
              _isPermissionGranted
                  ? const Column(
                    // Model yüklenirken de gösterge
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      CircularProgressIndicator(),
                      SizedBox(height: 10),
                      Text("Model yükleniyor veya kamera başlatılıyor..."),
                    ],
                  )
                  : const Text(
                    'Lütfen uygulama ayarlarından kamera iznini verin.',
                    textAlign: TextAlign.center,
                  ),
        ),
      );
    }

    final scale =
        1 /
        (_cameraController!.value.aspectRatio *
            MediaQuery.of(context).size.aspectRatio);
    final cameraPreview = Transform.scale(
      scale: scale < 1.0 ? 1.0 : scale,
      alignment: Alignment.topCenter,
      child: CameraPreview(_cameraController!),
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Akıllı Göz: Geri Dönüşüm Asistanı')),
      body: Column(
        children: <Widget>[
          Expanded(
            child: Container(
              alignment: Alignment.center,
              color: Colors.black,
              child: cameraPreview,
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Text(
              _resultText,
              style: const TextStyle(
                fontSize: 18.0,
                fontWeight: FontWeight.bold,
              ),
              textAlign: TextAlign.center,
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 16.0),
            child: Text(
              _bluetoothStatus,
              style: const TextStyle(fontSize: 14.0),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }
}

// lib/main.dart
import 'dart:io';
import 'dart:async';
import 'dart:typed_data';

import 'package:akilli_goz_app/bluetooth_service.dart'; // YENİ SERVİSİ IMPORT ET
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:image/image.dart' as img;
import 'package:wakelock_plus/wakelock_plus.dart';

late List<CameraDescription> _cameras;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    _cameras = await availableCameras();
  } on CameraException catch (e) {
    print('HATA: Kameralar alınamadı: ${e.code} - ${e.description}');
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
      theme: ThemeData(primarySwatch: Colors.teal),
      home: const HomeScreen(),
      debugShowCheckedModeBanner: false,
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
  // _HomeScreenState sınıfının içinde, diğer değişkenlerin yanına:
  String?
  _lastPredictedLabel; // Son başarılı ve gönderilen tahmini saklamak için
  // VEYA son gönderilen komut numarasını da saklayabilirsin:
  // int? _lastSentCommand;
  bool _isCameraInitialized = false;
  bool _isPermissionGranted = false;
  Interpreter? _interpreter;
  List<String> _labels = [];
  bool _isProcessingImage = false;
  TensorType _inputType = TensorType.uint8;
  TensorType _outputType = TensorType.uint8;
  int _inputImageSize = 224;

  // ---- BluetoothService INSTANCE'I OLUŞTUR ----
  late final AtikBluetoothService _bluetoothService;
  // ---------------------------------------------

  String _resultText = "Model bekleniyor...";
  // Bluetooth durumu artık AtikBluetoothService'ten gelecek
  // String _bluetoothStatus = "Bluetooth: Başlatılıyor..."; // Bu satırı kaldır

  @override
  void initState() {
    super.initState();
    // ---- BluetoothService'i başlat ve dinle ----
    _bluetoothService = AtikBluetoothService();
    _bluetoothService.addListener(
      _updateBluetoothStatusFromService,
    ); // Metot adını değiştir
    // -------------------------------------------
    _initialize(); // Diğer başlatma işlemleri
    WakelockPlus.enable();
    print("WakelockPlus etkinleştirildi.");
  }

  // BluetoothService'teki durumu UI'a yansıtmak için metot adı değişti
  void _updateBluetoothStatusFromService() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    WakelockPlus.disable();
    _bluetoothService.removeListener(_updateBluetoothStatusFromService);
    _bluetoothService
        .dispose(); // AtikBluetoothService'in kendi dispose'u çağrılır
    _cameraController?.stopImageStream().catchError((e) {});
    _cameraController?.dispose();
    _interpreter?.close();
    super.dispose();
  }

  Future<void> _initialize() async {
    await _requestPermissions(); // Bu fonksiyonu tekrar ekle
    if (_isPermissionGranted) {
      await _loadModelAndLabels();
      if (_interpreter != null) {
        _initializeCamera();
        // Bluetooth artık kendi içinde _initBluetooth'u çağırıyor
      } else {
        if (mounted) {
          setState(
            () =>
                _resultText = "Model yüklenemedi! Uygulamayı yeniden başlatın.",
          );
        }
        print("HATA: Interpreter null olduğu için kamera başlatılmadı.");
      }
    } else {
      if (mounted) {
        setState(
          () => _resultText = "Kamera ve gerekli diğer izinler verilmedi!",
        );
      }
      print("HATA: İzinler verilmediği için başlatma yapılamadı.");
    }
    // WakelockPlus.enable(); // Bu zaten initState içinde, burada tekrar gerek yok.
  }

  // ---- _requestPermissions FONKSİYONUNU EKLE ----
  Future<void> _requestPermissions() async {
    Map<Permission, PermissionStatus> statuses =
        await [
          Permission.camera,
          Permission.bluetoothScan, // Bluetooth izinlerini tekrar iste
          Permission.bluetoothConnect,
        ].request();
    if (mounted) {
      setState(() {
        _isPermissionGranted =
            statuses[Permission.camera] == PermissionStatus.granted &&
            statuses[Permission.bluetoothScan] == PermissionStatus.granted &&
            statuses[Permission.bluetoothConnect] == PermissionStatus.granted;
      });
    }
    if (!_isPermissionGranted)
      print("Gerekli izinler verilmedi.");
    else
      print("İzinler verildi.");
  }

  // ---------------------------------------------
  Future<void> _loadModelAndLabels() async {
    try {
      _interpreter = await Interpreter.fromAsset('assets/model.tflite');
      print("Interpreter başarıyla yüklendi.");

      var inputTensor = _interpreter!.getInputTensor(0);
      var outputTensor = _interpreter!.getOutputTensor(0);
      _inputType = inputTensor.type;
      _outputType = outputTensor.type;
      if (inputTensor.shape.length == 4) {
        _inputImageSize = inputTensor.shape[1];
      }
      print('--- MODEL TENSOR BİLGİSİ ---');
      print(
        'Girdi: Şekil=${inputTensor.shape}, Tip=$_inputType, Boyut=$_inputImageSize',
      );
      print('Çıktı: Şekil=${outputTensor.shape}, Tip=$_outputType');
      print('----------------------------');

      final labelsData = await rootBundle.loadString('assets/labels.txt');
      _labels =
          labelsData
              .split('\n')
              .map((line) {
                if (line.trim().isEmpty) return null;
                var parts = line.split(' ');
                return parts.length > 1
                    ? parts.sublist(1).join(' ').trim()
                    : line.trim();
              })
              .where((label) => label != null && label.isNotEmpty)
              .cast<String>()
              .toList();

      print('Etiketler yüklendi: $_labels (${_labels.length} adet)');
      if (_labels.isEmpty) {
        throw Exception(
          "Etiketler yüklenemedi veya labels.txt boş/hatalı formatta.",
        );
      }

      if (outputTensor.shape.length < 2 ||
          outputTensor.shape[1] != _labels.length) {
        print(
          "UYARI: Modelin çıktı boyutu (${outputTensor.shape.length > 1 ? outputTensor.shape[1] : 'N/A'}) ile etiket sayısı (${_labels.length}) uyuşmuyor!",
        );
      }
    } catch (e) {
      print('HATA: Model veya etiketler yüklenirken: $e');
      if (mounted) {
        setState(() => _resultText = "Model yükleme hatası!");
      }
      _interpreter = null;
    }
  }

  void _initializeCamera() {
    if (_cameras.isEmpty || _interpreter == null) {
      print("Kamera başlatılamıyor: Kamera listesi boş veya model yüklenmedi.");
      if (mounted && _interpreter == null) {
        // Model yüklenemediyse mesajı güncelle
        setState(
          () => _resultText = "Model yüklenemediği için kamera başlatılamıyor.",
        );
      }
      return;
    }
    if (_isCameraInitialized) {
      // Kamera zaten başlatıldıysa tekrar başlatma
      print("Kamera zaten başlatılmış.");
      return;
    }

    _cameraController = CameraController(
      _cameras[0],
      ResolutionPreset.medium, // Önce medium ile dene, gerekirse low yaparsın
      enableAudio: false,
      imageFormatGroup:
          Platform.isAndroid
              ? ImageFormatGroup.yuv420
              : ImageFormatGroup.bgra8888,
    );

    _cameraController!
        .initialize()
        .then((_) {
          if (!mounted) return;
          setState(() {
            _isCameraInitialized = true;
            _resultText = "Nesne gösterin...";
          });
          print("Kamera başarıyla başlatıldı.");
          _startImageStream(); // Görüntü akışını başlat
        })
        .catchError((e) {
          print('HATA: Kamera başlatılamadı: $e');
          if (mounted) {
            setState(() {
              _resultText = "Kamera başlatma hatası!";
              _isCameraInitialized = false;
            });
          }
        });
  }

  void _startImageStream() {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      print("Görüntü akışı başlatılamıyor: Kamera kontrolcüsü hazır değil.");
      return;
    }
    _cameraController!.stopImageStream().catchError((e) {
      print("Önceki stream durdurulurken hata (normal olabilir): $e");
    });

    _cameraController!.startImageStream((CameraImage cameraImage) {
      if (!_isProcessingImage && _interpreter != null && mounted) {
        _isProcessingImage = true;
        _processCameraImage(cameraImage);
      }
    });
    print("Görüntü akışı başlatıldı.");
  }
  /*
  //-------------------------------------------------------------------
  Future<void> _processCameraImage(CameraImage cameraImage) async {
    if (_interpreter == null || !_isCameraInitialized || _labels.isEmpty) {
      _isProcessingImage = false;
      return;
    }
    try {
      // ---- GİRDİ VERİSİNİ DÖNÜŞTÜR VE LOGLA ----
      Float32List? processedImageFloats; // Float32List veya null olabilir
      if (_inputType == TensorType.float32) {
        processedImageFloats = _convertCameraImageToFloatList(cameraImage);
        if (processedImageFloats != null && processedImageFloats.length >= 10) {
          print(
            ">>> Flutter _convertCameraImageToFloatList Çıktısı (ilk 10 normalize değer): "
            "${processedImageFloats.sublist(0, 10).map((f) => f.toStringAsFixed(3)).join(', ')}",
          );
        } else if (processedImageFloats != null) {
          print(
            ">>> Flutter _convertCameraImageToFloatList Çıktısı (kısa): $processedImageFloats",
          );
        } else {
          print(">>> HATA: _convertCameraImageToFloatList null döndürdü!");
        }
      } else {
        // Eğer model uint8 bekliyorsa (ki bizimki float32 bekliyor ama her ihtimale karşı)
        Uint8List? processedImageBytes = _convertCameraImageToUint8List(
          cameraImage,
        );
        if (processedImageBytes != null && processedImageBytes.length >= 10) {
          print(
            ">>> Flutter _convertCameraImageToUint8List Çıktısı (ilk 10 byte): "
            "${processedImageBytes.sublist(0, 10).join(', ')}",
          );
        } else if (processedImageBytes != null) {
          print(
            ">>> Flutter _convertCameraImageToUint8List Çıktısı (kısa): $processedImageBytes",
          );
        } else {
          print(">>> HATA: _convertCameraImageToUint8List null döndürdü!");
        }
        // Şimdilik uint8 durumunda TFLite çalıştırmayı atlayalım, çünkü modelimiz float32 bekliyor.
        _isProcessingImage = false;
        return;
      }
      // ---------------------------------------------

      if (processedImageFloats != null) {
        // Sadece float32 ile devam et
        int expectedOutputSize = _labels.length;
        dynamic outputData; // Tipini float32'ye göre ayarlayalım
        outputData = List.generate(
          1,
          (_) => List.filled(expectedOutputSize, 0.0),
        );

        // Girdiyi doğru şekle getir
        dynamic finalInput = processedImageFloats.reshape([
          1,
          _inputImageSize,
          _inputImageSize,
          3,
        ]);

        _interpreter!.run(finalInput, outputData);

        List<double> results = (outputData[0] as List<double>); // Çıktı float32

        int bestIndex = -1;
        double highestProb = -1.0;
        for (int i = 0; i < results.length; i++) {
          double prob = results[i]; // Zaten 0.0-1.0 arası
          if (prob > highestProb) {
            highestProb = prob;
            bestIndex = i;
          }
        }

        if (bestIndex != -1 &&
            bestIndex < _labels.length &&
            highestProb > 0.6) {
          String predictedLabel = _labels[bestIndex];
          if (mounted) {
            setState(() {
              _resultText =
                  "$predictedLabel (${(highestProb * 100).toStringAsFixed(1)}%)";
            });
          }
          print(
            "Tahmin: $predictedLabel (${(highestProb * 100).toStringAsFixed(1)}%)",
          );
          // Bluetooth komut gönderme (YORUMDA)
          // int commandToSend = ...;
          // _bluetoothService.sendCommand(commandToSend);
        }
      }
    } catch (e, stacktrace) {
      print("HATA: Görüntü işlenirken: $e\n$stacktrace");
      if (mounted) {
        setState(() => _resultText = "Tahmin hatası!");
      }
    } finally {
      await Future.delayed(const Duration(milliseconds: 500));
      if (mounted) {
        _isProcessingImage = false;
      }
    }
  }*/

  ///---------------------------------------------------

  Future<void> _processCameraImage(CameraImage cameraImage) async {
    if (_interpreter == null || !_isCameraInitialized || _labels.isEmpty) {
      _isProcessingImage = false;
      return;
    }
    try {
      dynamic inputDataRaw;
      if (_inputType == TensorType.float32) {
        inputDataRaw = _convertCameraImageToFloatList(cameraImage);
      } else {
        inputDataRaw = _convertCameraImageToUint8List(cameraImage);
      }

      if (inputDataRaw != null) {
        int expectedOutputSize = _labels.length;
        dynamic outputData;
        if (_outputType == TensorType.float32) {
          outputData = List.generate(
            1,
            (_) => List.filled(expectedOutputSize, 0.0),
          );
        } else {
          outputData = List.generate(
            1,
            (_) => List.filled(expectedOutputSize, 0),
          );
        }

        dynamic finalInput;
        if (_inputType == TensorType.float32) {
          finalInput = (inputDataRaw as Float32List).reshape([
            1,
            _inputImageSize,
            _inputImageSize,
            3,
          ]);
        } else {
          finalInput = (inputDataRaw as Uint8List).reshape([
            1,
            _inputImageSize,
            _inputImageSize,
            3,
          ]);
        }

        _interpreter!.run(finalInput, outputData);

        List<num> results;
        if (_outputType == TensorType.float32) {
          results = (outputData[0] as List<double>).cast<num>();
        } else {
          results = (outputData[0] as List<int>).cast<num>();
        }

        int bestIndex = -1;
        double highestProb = -1.0;
        for (int i = 0; i < results.length; i++) {
          double prob =
              (_outputType == TensorType.float32)
                  ? results[i].toDouble()
                  : results[i].toDouble() / 255.0;
          if (prob > highestProb) {
            highestProb = prob;
            bestIndex = i;
          }
        }

        if (bestIndex != -1 &&
            bestIndex < _labels.length &&
            highestProb > 0.7) {
          // Güven eşiğini biraz artırdım (isteğe bağlı)
          String currentPredictedLabel =
              _labels[bestIndex]; // Mevcut tahmini al

          if (mounted) {
            setState(() {
              _resultText =
                  "$currentPredictedLabel (${(highestProb * 100).toStringAsFixed(1)}%)";
            });

            // ---- YENİ MANTIK: Sadece etiket değiştiyse komut gönder ----
            if (currentPredictedLabel != _lastPredictedLabel) {
              print(
                ">>> Yeni Etiket Tespit Edildi: $currentPredictedLabel (Eski: $_lastPredictedLabel)",
              );

              int commandToSend = 0;
              print("Tahmin Edilen Etiket (işleniyor): $currentPredictedLabel");

              if (currentPredictedLabel == "1_Kagit") {
                commandToSend = 1;
              } else if (currentPredictedLabel == "2_Plastik") {
                commandToSend = 2;
              } else if (currentPredictedLabel == "3_Cam") {
                commandToSend = 3;
              } else if (currentPredictedLabel == "4_Metal") {
                commandToSend = 4;
              }
              // "GeriDonusur" için commandToSend 0 kalacak (veya özel bir işlem)

              print("Gönderilecek Komut (ESP32 için): $commandToSend");

              // 0 komutunu da gönderebiliriz (ESP32'de "Tanımsız" veya "Kompost" olarak işlenebilir)
              // veya sadece geçerli atık komutlarını gönderebiliriz (örn. if commandToSend != 0 && _bluetoothService.isConnected)
              if (_bluetoothService.isConnected) {
                // Bağlantı kontrolü
                _bluetoothService.sendCommand(commandToSend);
                _lastPredictedLabel =
                    currentPredictedLabel; // Komut gönderildikten sonra son etiketi güncelle
                print(
                  ">>> Komut gönderildi ve _lastPredictedLabel güncellendi: $_lastPredictedLabel",
                );
              } else {
                print("Bluetooth bağlı değil, komut gönderilemedi.");
              }
            } else {
              print(
                ">>> Etiket aynı kaldı ($currentPredictedLabel), komut gönderilmedi.",
              );
            }
            // ---------------------------------------------------------
          }
        } else {
          // Eğer güven eşiği altında kalırsa veya geçerli bir index bulunamazsa
          // son etiketi sıfırlayabiliriz ki bir sonraki geçerli tahmin gönderilsin.
          // _lastPredictedLabel = null; // VEYA _resultText'i "Tanımlanamadı" yapabiliriz.
          // if(mounted) {
          //   setState(() => _resultText = "Tanımlanamadı...");
          // }
        }
      }
    } catch (e, stacktrace) {
      print("HATA: Görüntü işlenirken: $e\n$stacktrace");
      if (mounted) {
        setState(() => _resultText = "Tahmin hatası!");
      }
    } finally {
      await Future.delayed(const Duration(milliseconds: 500)); // Gecikme
      if (mounted) {
        _isProcessingImage = false;
      }
    }
  }

  // Kamera görüntüsünü Float32List'e çevirir ve normalize eder (0.0 - 1.0)
  Float32List? _convertCameraImageToFloatList(CameraImage cameraImage) {
    try {
      final image = _convertCameraImageToImagePackage(cameraImage);
      if (image == null) {
        print("HATA: Float için img.Image oluşturulamadı.");
        return null;
      }
      final resizedImage = img.copyResize(
        image,
        width: _inputImageSize,
        height: _inputImageSize,
      );
      final imageFloats = Float32List(_inputImageSize * _inputImageSize * 3);
      int bufferIndex = 0;
      for (int y = 0; y < _inputImageSize; y++) {
        for (int x = 0; x < _inputImageSize; x++) {
          var pixel = resizedImage.getPixel(x, y);
          // Model BGR bekliyorsa, kanal sırasını değiştirin:
          // imageFloats[bufferIndex++] = img.getBlue(pixel) / 255.0;
          // imageFloats[bufferIndex++] = img.getGreen(pixel) / 255.0;
          // imageFloats[bufferIndex++] = img.getRed(pixel) / 255.0;
          // Model RGB bekliyorsa (mevcut kod):
          imageFloats[bufferIndex++] = img.getRed(pixel) / 255.0;
          imageFloats[bufferIndex++] = img.getGreen(pixel) / 255.0;
          imageFloats[bufferIndex++] = img.getBlue(pixel) / 255.0;
        }
      }
      return imageFloats;
    } catch (e, stacktrace) {
      print("HATA: Float görüntü dönüşümü: $e\n$stacktrace");
      return null;
    }
  }

  // Kamera görüntüsünü Uint8List'e çevirir (0-255)
  Uint8List? _convertCameraImageToUint8List(CameraImage cameraImage) {
    try {
      final image = _convertCameraImageToImagePackage(cameraImage);
      if (image == null) {
        print("HATA: Uint8 için img.Image oluşturulamadı.");
        return null;
      }
      final resizedImage = img.copyResize(
        image,
        width: _inputImageSize,
        height: _inputImageSize,
      );
      final imageBytes = Uint8List(_inputImageSize * _inputImageSize * 3);
      int pixelIndex = 0;
      for (int y = 0; y < _inputImageSize; y++) {
        for (int x = 0; x < _inputImageSize; x++) {
          var pixel = resizedImage.getPixel(x, y);

          imageBytes[pixelIndex++] = img.getRed(pixel).toInt();
          imageBytes[pixelIndex++] = img.getGreen(pixel).toInt();
          imageBytes[pixelIndex++] = img.getBlue(pixel).toInt();
        }
      }
      return imageBytes;
    } catch (e, stacktrace) {
      print("HATA: Uint8 görüntü dönüşümü: $e\n$stacktrace");
      return null;
    }
  }

  img.Image? _convertCameraImageToImagePackage(CameraImage cameraImage) {
    try {
      if (Platform.isAndroid) {
        if (cameraImage.format.group == ImageFormatGroup.yuv420)
          return _convertYUV420ToImage(cameraImage);
      } else if (Platform.isIOS) {
        if (cameraImage.format.group == ImageFormatGroup.bgra8888)
          return _convertBGRA8888ToImage(cameraImage);
      }
      print("Desteklenmeyen kamera formatı: ${cameraImage.format.group}");
      return null;
    } catch (e) {
      print("HATA: _convertCameraImageToImagePackage: $e");
      return null;
    }
  }

  img.Image _convertYUV420ToImage(CameraImage image) {
    // ... (Bu fonksiyonun içeriği bir önceki mesajdaki gibi doğru olmalı)
    // Örnek olarak, önceki doğru versiyonu tekrar ekliyorum:
    final int width = image.width;
    final int height = image.height;
    final int uvRowStride = image.planes[1].bytesPerRow;
    final int uvPixelStride = image.planes[1].bytesPerPixel!;
    final yPlane = image.planes[0].bytes;
    final uPlane = image.planes[1].bytes;
    final vPlane = image.planes[2].bytes;
    final img.Image rgbImage = img.Image(width, height); // Pozisyonel
    int yp = 0;
    for (int y = 0; y < height; y++) {
      int uvp = (y >> 1) * uvRowStride;
      int uVal = 0, vVal = 0; // Yerel değişkenler
      for (int x = 0; x < width; x++, yp++) {
        int r, g, b; // Yerel değişkenler
        int uvIndex = uvp + (x >> 1) * uvPixelStride;
        if (uvIndex >= uPlane.length || uvIndex >= vPlane.length) continue;
        try {
          uVal = image.planes[1].bytes[uvIndex];
          vVal = image.planes[2].bytes[uvIndex];
        } catch (e) {
          continue;
        }
        int yValue = yPlane[yp] & 0xFF;
        r = (yValue + (1.370705 * (vVal - 128))).toInt().clamp(0, 255);
        g = (yValue - (0.337633 * (uVal - 128)) - (0.698001 * (vVal - 128)))
            .toInt()
            .clamp(0, 255);
        b = (yValue + (1.732446 * (uVal - 128))).toInt().clamp(0, 255);
        rgbImage.setPixelRgba(x, y, r, g, b, 255);
      }
    }
    return rgbImage;
  }

  img.Image _convertBGRA8888ToImage(CameraImage image) {
    // ... (Bu fonksiyonun içeriği bir önceki mesajdaki gibi doğru olmalı)
    // Örnek olarak, önceki doğru versiyonu tekrar ekliyorum:
    return img.Image.fromBytes(
      image.width,
      image.height,
      image.planes[0].bytes,
    ); // Pozisyonel
  }

  // build metodu
  @override
  Widget build(BuildContext context) {
    Widget bodyWidget;
    if (!_isPermissionGranted) {
      bodyWidget = const Center(
        child: Padding(
          padding: EdgeInsets.all(16.0),
          child: Text('Kamera izni gerekli!', textAlign: TextAlign.center),
        ),
      );
    } else if (!_isCameraInitialized ||
        _cameraController == null ||
        _interpreter == null) {
      bodyWidget = const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 10),
            Text("Başlatılıyor..."),
          ],
        ),
      );
    } else {
      final scale =
          1 /
          (_cameraController!.value.aspectRatio *
              MediaQuery.of(context).size.aspectRatio);
      final cameraPreview = Transform.scale(
        scale: scale < 1.0 ? 1.0 : scale,
        alignment: Alignment.topCenter,
        child: CameraPreview(_cameraController!),
      );
      bodyWidget = Column(
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
              _bluetoothService.statusMessage, // SERVİSTEN AL
              style: const TextStyle(fontSize: 14.0, color: Colors.grey),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Akıllı Göz Model Testi')),
      body: bodyWidget,
    );
  }
}

import 'dart:io';
import 'dart:async'; // Timer için eklendi
import 'dart:typed_data'; // Uint8List için eklendi
import 'package:wakelock_plus/wakelock_plus.dart'; // YENİSİNİ EKLE
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'dart:convert'; // utf8 için
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

//-----------------------------------------------------
//        _HomeScreenState SINIFININ TAMAMI
//-----------------------------------------------------
class _HomeScreenState extends State<HomeScreen> {
  // BLE Değişkenleri
  BluetoothDevice? _targetDevice; // Bağlanılacak ESP32 cihazı
  BluetoothCharacteristic?
  _writeCharacteristic; // Komut yazılacak karakteristik
  StreamSubscription<BluetoothConnectionState>? _connectionStateSubscription;
  bool _isConnecting = false;
  bool _isConnected = false;

  // ESP32'nizin BLE Servis ve Karakteristik UUID'leri (Bunları ESP32 kodunuzdan almanız GEREKİR)
  // ** LÜTFEN BUNLARI KENDİ UUID'LERİNİZLE DEĞİŞTİRİN! **
  final Guid _serviceUuid = Guid(
    "4fafc201-1fb5-459e-8fcc-c5c9c331914b",
  ); // ÖRNEK
  final Guid _characteristicUuid = Guid(
    "beb5483e-36e1-4688-b7f5-ea07361b26a8",
  ); // ÖRNEK

  // Kamera ve TFLite Değişkenleri
  CameraController? _cameraController;
  bool _isCameraInitialized = false;
  bool _isPermissionGranted = false;
  Interpreter? _interpreter;
  List<String> _labels = []; // Etiket listesi
  bool _isProcessing =
      false; // Aynı anda birden fazla kare işlemeyi önlemek için
  Timer? _processingTimer; // Belirli aralıklarla işlem yapmak için (opsiyonel)

  final int _inputSize = 224; // Modelin giriş boyutları
  final bool _isQuantized = true; // Modelin quantize olup olmadığı

  String _resultText = "Nesne bekleniyor...";
  String _bluetoothStatus = "Bluetooth: Bağlı Değil";

  @override
  void initState() {
    super.initState();
    _requestPermissionsAndInitialize();
    WakelockPlus.enable();
    print("WakelockPlus etkinleştirildi.");
  }

  @override
  void dispose() {
    WakelockPlus.disable();
    print("WakelockPlus devre dışı bırakıldı.");
    _processingTimer?.cancel();
    _cameraController?.stopImageStream();
    _cameraController?.dispose();
    _interpreter?.close();
    _disconnect(); // Bağlantıyı kes
    super.dispose();
  }

  Future<void> _requestPermissionsAndInitialize() async {
    var cameraStatus = await Permission.camera.request();
    var bleScanStatus = await Permission.bluetoothScan.request();
    var bleConnectStatus = await Permission.bluetoothConnect.request();
    var locationStatus =
        await Permission.locationWhenInUse.request(); // Gerekebilir

    setState(() {
      _isPermissionGranted =
          cameraStatus.isGranted &&
          bleScanStatus.isGranted &&
          bleConnectStatus.isGranted;
    });

    if (_isPermissionGranted) {
      await _loadModel();
      _initializeCamera();
      _initBluetooth();
    } else {
      print("Gerekli izinler verilmedi.");
      setState(() {
        _resultText = "Kamera ve Bluetooth izinleri gerekli!";
      });
    }
  }

  Future<void> _loadModel() async {
    try {
      _interpreter = await Interpreter.fromAsset('assets/model.tflite');
      final labelsData = await rootBundle.loadString('assets/labels.txt');
      _labels =
          labelsData
              .split('\n')
              .map((label) => label.trim())
              .where((label) => label.isNotEmpty)
              .toList();
      print(
        'Model ve etiketler başarıyla yüklendi. Etiket sayısı: ${_labels.length}',
      );
    } catch (e) {
      print('Model veya etiketler yüklenirken hata oluştu: $e');
      setState(() {
        _resultText = "Model yüklenemedi!";
      });
    }
  }

  void _initializeCamera() {
    if (_cameras.isEmpty || _isCameraInitialized || _interpreter == null)
      return;

    final cameraDescription = _cameras[0];
    _cameraController = CameraController(
      cameraDescription,
      ResolutionPreset.low,
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
            _resultText = "Kameraya bir nesne gösterin";
          });
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

  void _startImageStream() {
    _cameraController?.startImageStream((CameraImage cameraImage) {
      if (_isProcessing || _interpreter == null) return;
      _isProcessing = true;
      _processCameraImage(cameraImage);
    });
    print("Görüntü akışı başlatıldı.");
  }

  Future<void> _processCameraImage(CameraImage cameraImage) async {
    if (_interpreter == null || !_isCameraInitialized) return;

    try {
      var inputBytes = _convertCameraImage(cameraImage);
      if (inputBytes != null) {
        // Etiket sayısı kontrolü
        if (_labels.isEmpty) {
          print("Hata: Etiket listesi boş!");
          return;
        }
        // Çıkış tensör boyutunu kontrol et
        int expectedOutputSize = _labels.length;
        if (expectedOutputSize <= 0) {
          print("Hata: Geçersiz etiket sayısı: $expectedOutputSize");
          return;
        }

        var output = List.filled(
          1 * expectedOutputSize,
          0,
        ).reshape([1, expectedOutputSize]);

        _interpreter!.run(inputBytes, output);
        var results = output[0] as List<num>;
        int bestIndex = -1;
        double highestProb = -1.0;

        for (int i = 0; i < results.length; i++) {
          // Çıkış sınırlarını kontrol et
          if (i >= expectedOutputSize) {
            print(
              "Hata: Sonuç indeksi ($i) etiket sayısını ($expectedOutputSize) aşıyor.",
            );
            break; // Döngüden çık
          }
          double prob =
              _isQuantized
                  ? results[i].toDouble() / 255.0
                  : results[i].toDouble();
          if (prob > highestProb) {
            highestProb = prob;
            bestIndex = i;
          }
        }

        if (bestIndex != -1 &&
            bestIndex < _labels.length &&
            highestProb > 0.6) {
          // bestIndex kontrolü eklendi
          String fullLabel = _labels[bestIndex];
          String predictedLabel = fullLabel.split(' ').last;

          if (mounted) {
            setState(() {
              _resultText =
                  "$fullLabel (${(highestProb * 100).toStringAsFixed(1)}%)";
            });

            int commandToSend = 0;
            print("Tahmin Edilen Etiket: $predictedLabel");

            if (predictedLabel == "kitab") {
              commandToSend = 1;
            } else if (predictedLabel == "sise") {
              commandToSend = 3;
            } // Plastik varsayımı
            else if (predictedLabel == "fare") {
              commandToSend = 4;
            } // Metal varsayımı
            // else if (predictedLabel == "insan") { commandToSend = 0; } // İnsan için komut göndermeyelim
            // ... diğer etiketler ...

            print("Gönderilecek Komut: $commandToSend");
            if (commandToSend != 0) {
              _sendBluetoothCommand(commandToSend);
            }
          }
        }
      }
    } catch (e, stacktrace) {
      print("Görüntü işlenirken hata: $e");
      print("Stacktrace: $stacktrace");
    } finally {
      _isProcessing = false;
      await Future.delayed(const Duration(milliseconds: 100));
    }
  }

  Uint8List? _convertCameraImage(CameraImage cameraImage) {
    img.Image? image;
    try {
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
      var imageBytes = Uint8List(_inputSize * _inputSize * 3);
      int pixelIndex = 0;
      for (int y = 0; y < _inputSize; y++) {
        for (int x = 0; x < _inputSize; x++) {
          var pixel = resizedImage.getPixel(x, y);
          imageBytes[pixelIndex++] = img.getRed(pixel).toInt();
          imageBytes[pixelIndex++] = img.getGreen(pixel).toInt();
          imageBytes[pixelIndex++] = img.getBlue(pixel).toInt();
        }
      }
      return imageBytes;
    } catch (e, stacktrace) {
      print("Görüntü dönüştürme hatası: $e");
      print("Stacktrace: $stacktrace");
      return null;
    }
  }

  img.Image _convertYUV420(CameraImage image) {
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
      int u = 0, v = 0;
      for (int x = 0; x < width; x++, yp++) {
        int uvIndex = uvp + (x >> 1) * uvPixelStride;
        if (uvIndex >= uPlane.length || uvIndex >= vPlane.length) continue;
        try {
          u = image.planes[1].bytes[uvIndex];
          v = image.planes[2].bytes[uvIndex];
        } catch (e) {
          print("Error accessing UV planes at index $uvIndex: $e");
          continue;
        }
        int yValue = yPlane[yp] & 0xFF;
        int r = (yValue + (1.370705 * (v - 128))).toInt().clamp(0, 255);
        int g = (yValue - (0.337633 * (u - 128)) - (0.698001 * (v - 128)))
            .toInt()
            .clamp(0, 255);
        int b = (yValue + (1.732446 * (u - 128))).toInt().clamp(0, 255);
        rgbImage.setPixelRgba(x, y, r, g, b, 255);
      }
    }
    return rgbImage;
  }

  img.Image _convertBGRA8888(CameraImage image) {
    return img.Image.fromBytes(
      image.width,
      image.height,
      image.planes[0].bytes,
    );
  }

  // ------------- BLUETOOTH FONKSİYONLARI -------------

  Future<void> _initBluetooth() async {
    if (await FlutterBluePlus.isSupported == false) {
      print("BLE is not supported by this device");
      setState(() => _bluetoothStatus = "BLE Desteklenmiyor");
      return;
    }

    FlutterBluePlus.adapterState.listen((BluetoothAdapterState state) {
      print("BLE Adapter State: $state");
      if (mounted) {
        setState(
          () => _bluetoothStatus = "BLE: ${state.toString().split('.')[1]}",
        );
        if (state == BluetoothAdapterState.on &&
            !_isConnected &&
            !_isConnecting) {
          _scanAndConnect();
        } else if (state == BluetoothAdapterState.off) {
          _disconnect();
        }
      }
    });

    final connectedDevices = await FlutterBluePlus.connectedDevices;
    for (BluetoothDevice d in connectedDevices) {
      // ** KENDİ CİHAZ ADIN VEYA MAC ADRESİNLE DEĞİŞTİR **
      if (d.platformName == "ESP32_TrashBin") {
        print("Cihaz zaten bağlı: ${d.platformName}");
        _targetDevice = d;
        await _setupConnection(_targetDevice!);
        return;
      }
    }

    if (await FlutterBluePlus.adapterState.first == BluetoothAdapterState.on) {
      _scanAndConnect();
    }
  }

  Future<void> _setupConnection(BluetoothDevice device) async {
    if (mounted) {
      setState(() {
        _isConnected = true;
        _isConnecting = false;
        _bluetoothStatus = "BLE: Önceden Bağlı";
      });
      _connectionStateSubscription?.cancel();
      _connectionStateSubscription = device.connectionState.listen((
        BluetoothConnectionState state,
      ) {
        if (mounted) {
          setState(() {
            _isConnected = state == BluetoothConnectionState.connected;
            _bluetoothStatus =
                _isConnected ? "BLE: Bağlandı" : "BLE: Bağlantı Kesildi";
            _isConnecting = false;
          });
          if (!_isConnected) {
            _writeCharacteristic = null;
            // Future.delayed(const Duration(seconds: 5), () { if(mounted) _scanAndConnect(); }); // Otomatik tekrar bağlanma
          }
        }
      });
      await _discoverServices(device);
    }
  }

  Future<void> _scanAndConnect() async {
    if (_isConnecting || _isConnected) return;
    setState(() {
      _isConnecting = true;
      _bluetoothStatus = "BLE: Cihaz Aranıyor...";
    });

    try {
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 5));

      StreamSubscription? scanSubscription; // Dinleyiciyi tutmak için
      scanSubscription = FlutterBluePlus.scanResults.listen((results) {
        for (ScanResult r in results) {
          // ** KENDİ CİHAZ ADINLA DEĞİŞTİR **
          if (r.device.platformName == "ESP32_TrashBin") {
            print(
              'Hedef Cihaz Bulundu: ${r.device.platformName} (${r.device.remoteId})',
            );
            FlutterBluePlus.stopScan(); // Taramayı durdur
            scanSubscription?.cancel(); // Dinleyiciyi iptal et
            _targetDevice = r.device;
            _connectToDevice(_targetDevice!); // Bağlanmayı başlat
            return; // Fonksiyondan çık
          }
        }
      });

      // Tarama zaman aşımına uğradığında veya durduğunda dinleyiciyi iptal et
      await FlutterBluePlus.isScanning.where((val) => val == false).first;
      scanSubscription?.cancel(); // Tarama bittiğinde dinleyiciyi temizle

      // Zaman aşımı sonrası kontrol
      await Future.delayed(const Duration(milliseconds: 100)); // Kısa bekleme
      if (!_isConnected && _targetDevice == null && mounted) {
        print("Hedef cihaz bulunamadı.");
        setState(() {
          _bluetoothStatus = "BLE: Cihaz Bulunamadı";
          _isConnecting = false;
        });
      }
    } catch (e) {
      print("Tarama sırasında hata: $e");
      if (mounted) {
        setState(() {
          _bluetoothStatus = "BLE: Tarama Hatası";
          _isConnecting = false;
        });
      }
    }
  }

  Future<void> _connectToDevice(BluetoothDevice device) async {
    if (_isConnected) return;
    setState(() => _bluetoothStatus = "BLE: Bağlanılıyor...");

    _connectionStateSubscription?.cancel(); // Önceki dinleyiciyi iptal et
    _connectionStateSubscription = device.connectionState.listen(
      (BluetoothConnectionState state) {
        if (mounted) {
          setState(() {
            _isConnected = state == BluetoothConnectionState.connected;
            _bluetoothStatus =
                _isConnected ? "BLE: Bağlandı" : "BLE: Bağlantı Kesildi";
            _isConnecting = false;
          });
          if (_isConnected) {
            _discoverServices(device);
          } else {
            _writeCharacteristic = null;
            // Tekrar bağlanmayı dene?
            // Future.delayed(const Duration(seconds: 5), () { if(mounted && !_isConnecting) _scanAndConnect(); });
          }
        }
      },
      onError: (error) {
        // Hata durumunu da dinle
        print("Bağlantı durumu hatası: $error");
        if (mounted) {
          setState(() {
            _isConnected = false;
            _isConnecting = false;
            _bluetoothStatus = "BLE: Bağlantı Hatası";
          });
        }
      },
    );

    try {
      await device.connect(timeout: Duration(seconds: 15)); // Zaman aşımı ekle
    } catch (e) {
      print("Bağlanma hatası: $e");
      if (mounted) {
        setState(() {
          _bluetoothStatus = "BLE: Bağlantı Hatası";
          _isConnecting = false;
        });
      }
    }
  }

  Future<void> _discoverServices(BluetoothDevice device) async {
    if (!_isConnected) return;
    setState(() => _bluetoothStatus = "BLE: Servisler Keşfediliyor...");
    try {
      List<BluetoothService> services = await device.discoverServices();
      bool characteristicFound = false; // Karakteristik bulundu mu flag'i
      for (BluetoothService service in services) {
        if (service.uuid == _serviceUuid) {
          print("Hedef Servis Bulundu: ${service.uuid}");
          for (BluetoothCharacteristic characteristic
              in service.characteristics) {
            if (characteristic.uuid == _characteristicUuid &&
                (characteristic.properties.write ||
                    characteristic.properties.writeWithoutResponse)) {
              // Yazma özelliğini kontrol et
              print("Hedef Karakteristik Bulundu: ${characteristic.uuid}");
              if (mounted) {
                setState(() {
                  _writeCharacteristic = characteristic;
                  _bluetoothStatus = "BLE: Hazır";
                });
              }
              characteristicFound = true;
              break; // İç döngüden çık
            }
          }
        }
        if (characteristicFound) break; // Dış döngüden de çık
      }
      if (!characteristicFound && mounted) {
        print("Hedef servis veya yazılabilir karakteristik bulunamadı.");
        setState(() => _bluetoothStatus = "BLE: Karakteristik Bulunamadı");
      }
    } catch (e) {
      print("Servis keşfi sırasında hata: $e");
      if (mounted)
        setState(() => _bluetoothStatus = "BLE: Servis Keşfi Hatası");
    }
  }

  Future<void> _sendBluetoothCommand(int commandValue) async {
    if (_writeCharacteristic != null && _isConnected) {
      try {
        List<int> bytesToSend = [commandValue];
        // Yazma türünü kontrol et (withoutResponse daha hızlıdır)
        bool canWriteWithoutResponse =
            _writeCharacteristic!.properties.writeWithoutResponse;
        await _writeCharacteristic!.write(
          bytesToSend,
          withoutResponse: canWriteWithoutResponse,
        );
        print(
          "BLE Komutu Gönderildi: $commandValue (withoutResponse: $canWriteWithoutResponse)",
        );
      } catch (e) {
        print("BLE komutu gönderilirken hata: $e");
        if (mounted) setState(() => _bluetoothStatus = "BLE: Yazma Hatası");
      }
    } else {
      print(
        "BLE komutu gönderilemedi: Bağlı değil veya karakteristik bulunamadı.",
      );
      if (!_isConnected && !_isConnecting && mounted) {
        _scanAndConnect(); // Bağlı değilse tekrar bağlanmayı dene
      }
    }
  }

  Future<void> _disconnect() async {
    _connectionStateSubscription?.cancel();
    _connectionStateSubscription = null;
    try {
      await _targetDevice?.disconnect();
    } catch (e) {
      print("Disconnect hatası: $e");
    }
    if (mounted) {
      setState(() {
        _isConnected = false;
        _isConnecting = false;
        _writeCharacteristic = null;
        _targetDevice = null; // Cihazı null yapalım ki tekrar tarasın
        _bluetoothStatus = "BLE: Bağlantı Kesildi";
      });
    }
    print("BLE Bağlantısı kesildi.");
  }

  // ------------- BUILD METODU -------------
  @override
  Widget build(BuildContext context) {
    // Yükleme veya izin ekranı
    if (!_isPermissionGranted ||
        !_isCameraInitialized ||
        _cameraController == null ||
        _interpreter == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Akıllı Göz')),
        body: Center(
          child:
              _isPermissionGranted
                  ? const Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      CircularProgressIndicator(),
                      SizedBox(height: 10),
                      Text("Başlatılıyor..."),
                    ],
                  )
                  : const Padding(
                    padding: EdgeInsets.all(16.0),
                    child: Text(
                      'Uygulamayı kullanmak için lütfen Kamera ve Bluetooth izinlerini verin.',
                      textAlign: TextAlign.center,
                    ),
                  ),
        ),
      );
    }

    // Kamera önizleme oranı ayarı
    final scale =
        1 /
        (_cameraController!.value.aspectRatio *
            MediaQuery.of(context).size.aspectRatio);
    final cameraPreview = Transform.scale(
      scale: scale < 1.0 ? 1.0 : scale,
      alignment: Alignment.topCenter,
      child: CameraPreview(_cameraController!),
    );

    // Ana ekran yapısı
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
} // <- BU SATIRIN SONUNDA EKSİK OLAN KAPANIŞ PARANTEZİ '}'

//-----------------------------------------------------
//     _HomeScreenState SINIFININ SONU
//-----------------------------------------------------

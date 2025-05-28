// lib/bluetooth_service.dart
import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart'
    as fbp; // İsim çakışmasını önlemek için alias

// ---- SINIF ADI DEĞİŞTİ ----
class AtikBluetoothService extends ChangeNotifier {
  // ---------------------------
  // ESP32 UUID'leri (KULLANICI BUNLARI KENDİSİNE GÖRE AYARLAMALI)
  final fbp.Guid _serviceUuid = fbp.Guid(
    "4fafc201-1fb5-459e-8fcc-c5c9c331914b",
  );
  final fbp.Guid _characteristicUuid = fbp.Guid(
    "beb5483e-36e1-4688-b7f5-ea07361b26a8",
  );
  final String _targetDeviceName = "ESP32_TrashBin";

  fbp.BluetoothDevice? _targetDevice;
  fbp.BluetoothCharacteristic? _writeCharacteristic;
  StreamSubscription<fbp.BluetoothConnectionState>?
  _connectionStateSubscription;
  StreamSubscription<List<fbp.ScanResult>>? _scanSubscription;

  bool _isConnecting = false;
  bool _isConnected = false;
  String _statusMessage = "Bluetooth: Başlatılıyor...";
  // Durumları dışarıya bildirmek için ValueNotifier kullanılabilir veya doğrudan getter'lar
  bool get isConnected => _isConnected;
  bool get isConnecting => _isConnecting;
  String get statusMessage => _statusMessage;

  AtikBluetoothService() {
    // Kurucu metot adı da değişti
    _initBluetooth();
  }
  Future<void> _initBluetooth() async {
    if (await fbp.FlutterBluePlus.isSupported == false) {
      print("BLE Desteklenmiyor");
      _updateStatus("BLE Desteklenmiyor");
      return;
    }

    fbp.FlutterBluePlus.adapterState.listen((fbp.BluetoothAdapterState state) {
      print("BLE Adapter State: $state");
      _updateStatus("BLE: ${state.toString().split('.').last}");
      if (state == fbp.BluetoothAdapterState.on &&
          !_isConnected &&
          !_isConnecting) {
        scanAndConnect();
      } else if (state == fbp.BluetoothAdapterState.off) {
        disconnect();
      }
    });

    try {
      final connectedDevices = await fbp.FlutterBluePlus.connectedDevices;
      for (fbp.BluetoothDevice d in connectedDevices) {
        if (d.platformName == _targetDeviceName) {
          print("Cihaz zaten bağlı: ${d.platformName}");
          _targetDevice = d;
          await _setupExistingConnection(_targetDevice!);
          return;
        }
      }
      if (await fbp.FlutterBluePlus.adapterState.first ==
          fbp.BluetoothAdapterState.on) {
        scanAndConnect();
      }
    } catch (e) {
      print("Başlangıçta bağlı cihaz kontrol hatası: $e");
      _updateStatus("BLE: Başlangıç Hatası");
    }
  }

  void _updateStatus(String message) {
    _statusMessage = message;
    notifyListeners(); // Değişikliği dinleyen widget'ları uyar
  }

  Future<void> _setupExistingConnection(fbp.BluetoothDevice device) async {
    print(">>> _setupExistingConnection başladı. Cihaz: ${device.remoteId}");
    _targetDevice = device; // _targetDevice'ı burada da set et
    _isConnected = true;
    _isConnecting = false;
    _updateStatus("BLE: Önceden Bağlı");
    _listenToConnectionState(device);
    await _discoverServices(device);
  }

  Future<void> scanAndConnect() async {
    // ... (içerik aynı, sadece tipler fbp. ile belirtilecek)
    if (_isConnecting || _isConnected) return;
    print(">>> _scanAndConnect başladı.");
    _isConnecting = true;
    _updateStatus("BLE: Cihaz Aranıyor...");
    _targetDevice = null;
    await _scanSubscription?.cancel();
    _scanSubscription = null;
    try {
      await fbp.FlutterBluePlus.startScan(timeout: const Duration(seconds: 7));
      print(">>> Tarama başlatıldı.");
      _scanSubscription = fbp.FlutterBluePlus.scanResults.listen(
        (results) {
          if (!_isConnecting || _targetDevice != null) return;
          for (fbp.ScanResult r in results) {
            if (r.device.platformName == _targetDeviceName) {
              print(
                '>>> Hedef Cihaz Bulundu: ${r.device.platformName} (${r.device.remoteId})',
              );
              fbp.FlutterBluePlus.stopScan();
              _scanSubscription?.cancel();
              _scanSubscription = null;
              _targetDevice = r.device;
              _connectToDevice(_targetDevice!);
              return;
            }
          }
        },
        onError: (error) {
          print(">>> !!! Tarama Dinleyici Hatası: $error");
          _updateStatus("BLE: Tarama Hatası");
          _isConnecting = false;
          _scanSubscription?.cancel();
          _scanSubscription = null;
        },
      );

      await fbp.FlutterBluePlus.isScanning.where((val) => val == false).first;
      print(">>> Tarama tamamlandı veya durduruldu.");
      _scanSubscription?.cancel();
      _scanSubscription = null;

      await Future.delayed(const Duration(milliseconds: 100));
      if (!_isConnected && _targetDevice == null && _isConnecting) {
        print(">>> Hedef cihaz tarama süresi içinde bulunamadı.");
        _updateStatus("BLE: Cihaz Bulunamadı");
        _isConnecting = false;
      }
    } catch (e) {
      print(">>> !!! Tarama/Bağlanma genel hata: $e");
      _updateStatus("BLE: Genel Hata");
      _isConnecting = false;
      _scanSubscription?.cancel();
      _scanSubscription = null;
    }
  }

  void _listenToConnectionState(fbp.BluetoothDevice device) {
    _connectionStateSubscription?.cancel();
    _connectionStateSubscription = device.connectionState.listen(
      (fbp.BluetoothConnectionState state) {
        print(">>> Bağlantı Durumu Değişti: $state için ${device.remoteId}");
        bool wasConnected = _isConnected;
        _isConnected = state == fbp.BluetoothConnectionState.connected;
        _isConnecting = state == fbp.BluetoothConnectionState.connecting;

        if (_isConnected != wasConnected ||
            _isConnecting ||
            state == fbp.BluetoothConnectionState.disconnected) {
          _updateStatus("BLE: ${state.toString().split('.').last}");
        }

        if (_isConnected) {
          if (!wasConnected) {
            // Sadece yeni bağlandıysa servis keşfet
            print(">>> Bağlantı başarılı, servisler keşfedilecek...");
            _discoverServices(device);
          }
        } else {
          print(
            ">>> Bağlantı koptu veya başarısız oldu for ${device.remoteId}",
          );
          _writeCharacteristic = null;
          // Bağlantı tamamen koptuysa ve hala bu cihaz hedefleniyorsa yeniden taramayı dene
          if (_targetDevice?.remoteId == device.remoteId && !_isConnecting) {
            print(
              ">>> Otomatik tekrar bağlanma denemesi için tarama başlatılıyor...",
            );
            Future.delayed(const Duration(seconds: 3), () {
              if (!_isConnected && !_isConnecting) scanAndConnect();
            });
          }
        }
      },
      onError: (error) {
        print(">>> !!! Bağlantı Durumu Dinleyici Hatası: $error");
        _updateStatus("BLE: Bağlantı Dinleyici Hatası");
        _isConnected = false;
        _isConnecting = false;
      },
    );
  }

  Future<void> _connectToDevice(fbp.BluetoothDevice device) async {
    if (_isConnected && _targetDevice?.remoteId == device.remoteId) {
      print("Zaten bu cihaza bağlı, bağlanma atlanıyor.");
      return;
    }
    print(">>> _connectToDevice fonksiyonu başladı. Cihaz: ${device.remoteId}");
    if (!_isConnecting) _isConnecting = true; // Bağlanma sürecini başlat
    _updateStatus("BLE: Bağlanılıyor...");

    _listenToConnectionState(device); // Dinleyiciyi başlat/güncelle

    try {
      print(">>> device.connect çağrılıyor (timeout: 20s)...");
      await device.connect(timeout: const Duration(seconds: 20));
      print(
        ">>> device.connect çağrısı tamamlandı (sonuç dinleyicide işlenecek).",
      );
    } catch (e) {
      print(">>> !!! device.connect içinde HATA: $e");
      _updateStatus("BLE: Bağlantı Hatası");
      _isConnected = false;
      _isConnecting = false;
      _connectionStateSubscription?.cancel();
      _connectionStateSubscription = null;
    }
  }

  Future<void> _discoverServices(fbp.BluetoothDevice device) async {
    if (!_isConnected) return;
    print(">>> _discoverServices başladı. Cihaz: ${device.remoteId}");
    _updateStatus("BLE: Servisler Keşfediliyor...");
    List<fbp.BluetoothService> services = [];
    try {
      services = await device.discoverServices().timeout(
        const Duration(seconds: 15),
      );
      print(
        ">>> Servisler keşfedildi, toplam ${services.length} servis bulundu.",
      );
      bool characteristicFound = false;
      for (fbp.BluetoothService service in services) {
        print(">>> Bulunan Servis UUID: ${service.uuid}");
        if (service.uuid == _serviceUuid) {
          print(">>> !!! Hedef Servis Bulundu: ${service.uuid}");
          for (fbp.BluetoothCharacteristic characteristic
              in service.characteristics) {
            print(
              ">>> Bulunan Karakteristik UUID: ${characteristic.uuid}, Özellikler: ${characteristic.properties}",
            );
            if (characteristic.uuid == _characteristicUuid &&
                (characteristic.properties.write ||
                    characteristic.properties.writeWithoutResponse)) {
              print(
                ">>> !!! Hedef Karakteristik Bulundu: ${characteristic.uuid}",
              );
              _writeCharacteristic = characteristic;
              _updateStatus("BLE: Hazır");
              characteristicFound = true;
              break;
            }
          }
        }
        if (characteristicFound) break;
      }
      if (!characteristicFound) {
        print(
          ">>> HATA: Hedef servis veya yazılabilir karakteristik bulunamadı!",
        );
        _updateStatus("BLE: Karakteristik Bulunamadı");
      }
    } on TimeoutException catch (e) {
      print(">>> !!! Servis keşfi ZAMAN AŞIMINA UĞRADI: $e");
      _updateStatus("BLE: Servis Zaman Aşımı");
    } catch (e, stacktrace) {
      print(">>> !!! Servis keşfi sırasında HATA: $e\n$stacktrace");
      _updateStatus("BLE: Servis Keşfi Hatası");
    } finally {
      print(
        ">>> _discoverServices tamamlandı. Bulunan servis sayısı: ${services.length}",
      );
    }
  }

  Future<void> sendCommand(int commandValue) async {
    if (_writeCharacteristic == null) {
      print("HATA: Karakteristik null. Komut gönderilemedi.");
      _updateStatus("BLE: Yazma Başarısız (Karakteristik Yok)");
      if (!_isConnected && !_isConnecting) scanAndConnect();
      return;
    }
    if (!_isConnected) {
      print("HATA: Cihaz bağlı değil. Komut gönderilemedi.");
      _updateStatus("BLE: Yazma Başarısız (Bağlı Değil)");
      if (!_isConnecting) scanAndConnect();
      return;
    }

    try {
      Uint8List bytesToSend = Uint8List.fromList([commandValue]);
      print(">>> Gönderilecek Değer (Uint8List): $commandValue ($bytesToSend)");

      // ESP32 sadece PROPERTY_WRITE desteklediği için withoutResponse: false kullanıyoruz
      if (_writeCharacteristic!.properties.write) {
        print(">>> Yazma deneniyor (withResponse)... Değer: $commandValue");
        await _writeCharacteristic!.write(
          bytesToSend,
          withoutResponse: false,
          timeout: 5,
        ); // Timeout ekleyelim
        print(">>> Yazma BAŞARILI (withResponse): $commandValue");
        _updateStatus("BLE: Komut Gönderildi ($commandValue)");
      } else if (_writeCharacteristic!.properties.writeWithoutResponse) {
        // Bu bloğa normalde girmemeli ama güvenlik için
        print(">>> Yazma deneniyor (withoutResponse)... Değer: $commandValue");
        await _writeCharacteristic!.write(
          bytesToSend,
          withoutResponse: true,
          timeout: 5,
        );
        print(">>> Yazma BAŞARILI (withoutResponse): $commandValue");
        _updateStatus("BLE: Komut Gönderildi ($commandValue)");
      } else {
        print(">>> Hata: Karakteristik yazmayı DESTEKLEMİYOR.");
        _updateStatus("BLE: Yazma Desteklenmiyor");
      }
    } catch (e) {
      print(">>> !!! BLE YAZMA HATASI !!! Değer: $commandValue\nHata: $e");
      _updateStatus("BLE: Yazma Hatası");
    }
  }

  Future<void> disconnect() async {
    print(">>> disconnect çağrıldı.");
    await _scanSubscription?.cancel();
    _scanSubscription = null;
    await _connectionStateSubscription?.cancel();
    _connectionStateSubscription = null;
    try {
      if (_targetDevice != null) {
        await _targetDevice!.disconnect();
        print(">>> Disconnect isteği gönderildi: ${_targetDevice!.remoteId}");
      }
    } catch (e) {
      print(">>> Disconnect hatası: $e");
    }
    _isConnected = false;
    _isConnecting = false;
    _writeCharacteristic = null;
    _targetDevice = null;
    _updateStatus("BLE: Bağlantı Kesildi");
    print(">>> BLE Bağlantısı kesildi (state güncellendi).");
  }

  // Widget dispose olduğunda çağrılır
  @override
  void dispose() {
    print("AtikBluetoothService dispose ediliyor.");
    disconnect(); // Bluetooth bağlantılarını ve dinleyicilerini temizle
    super.dispose(); // ChangeNotifier'ın kendi dispose'unu çağır
  }
}

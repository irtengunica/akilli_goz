# Akıllı Göz: Yapay Zekâ ile Atıkları Tanıyan ve Ayıran Sistem


**TÜBİTAK 4006 Bilim Fuarı Projesi**

Bu proje, atıkların kaynağında doğru bir şekilde ayrıştırılmasını otomatikleştirmeyi hedefleyen, yapay zekâ destekli akıllı bir çöp kutusu prototipidir. Sistem, içine atılan nesneleri kamera aracılığıyla tanır ve uygun geri dönüşüm bölmesine yönlendirir.

## 🎯 Proje Amacı

Projemizin temel amacı, günlük hayatta karşılaştığımız atık ayrıştırma sorununa teknolojik bir çözüm sunmaktır. Bu kapsamda hedeflerimiz:

1.  🗑️ Atılan atıkların türünü (kağıt, plastik, metal, cam, kompost) yapay zekâ ile yüksek doğrulukla tanımlamak.
2.  🤖 Tanımlanan atık türüne göre, atığı uygun geri dönüşüm bölmesine otomatik olarak yönlendiren bir mekanizma geliştirmek.
3.  ♻️ Geri dönüşüm süreçlerinin verimliliğini artırmak ve yanlış ayrıştırılmış atık oranını düşürmek.
4.  💡 Teknoloji destekli bu çözümle toplumda geri dönüşüm bilincini artırmak.
5.  🌍 Doğal kaynak kullanımını azaltarak ve çevre kirliliğini minimize ederek sürdürülebilir bir geleceğe katkıda bulunmak.

## ✨ Temel Özellikler

*   **Görüntü Tanıma:** Tensorflow Lite modeli kullanılarak atıkların gerçek zamanlı sınıflandırılması.
*   **Otomatik Ayrıştırma:** Tespit edilen atık türüne göre çalışan step motor ve servo motor kontrollü mekanik ayrıştırma sistemi.
*   **Kontrol Arayüzü:** (Şu an için) Bilgisayar kamerası ve Python script'i ile kontrol. (Gelecekte mobil uygulama entegrasyonu hedeflenmektedir).
*   **Donanım:** Arduino Uno (veya ESP32) mikrodenetleyici, 28BYJ-48 step motor, ULN2003A sürücü kartı, (isteğe bağlı servo motor).

## 🛠️ Nasıl Çalışır?

1.  **Atık Atma:** Kullanıcı atığı kutunun kamera görüş alanına bırakır.
2.  **Görüntü Alma:** Bağlı kamera (şu an için bilgisayar kamerası) atığın görüntüsünü yakalar.
3.  **Yapay Zekâ Analizi:** Python script'i, yakalanan görüntüyü önceden eğitilmiş TFLite modeline gönderir. Model, atığın türünü (örn. Kağıt, Plastik) tahmin eder.
4.  **Komut Gönderme:** Tespit edilen türe karşılık gelen bir komut (örn. Kağıt için `1`) USB üzerinden seri port aracılığıyla Arduino'ya (veya ESP32'ye) gönderilir.
5.  **Mekanik Ayrıştırma:** Arduino, aldığı komuta göre step motoru çalıştırarak atık kutusunun içindeki yönlendirici mekanizmayı doğru bölmeye çevirir. (Eğer varsa) Servo motor da kapağı açıp atığın o bölmeye düşmesini sağlar ve sonra kapağı kapatır. Step motor başlangıç pozisyonuna döner.

## 💻 Kullanılan Teknolojiler ve Kütüphaneler

*   **Yapay Zekâ Modeli:**
    *   Google Colab üzerinde Python, TensorFlow, Keras
    *   Temel Model: MobileNetV2 (Transfer Learning ile)
    *   Veri Seti: TrashNet (projemize özel 5 sınıfa göre düzenlendi: Kompost, Kağıt, Plastik, Cam, Metal)
    *   Model Formatı: TensorFlow Lite (.tflite)
*   **Kontrol ve Görüntü İşleme (Bilgisayar):**
    *   Python
    *   OpenCV (`cv2`): Kamera görüntüsü alma ve gösterme
    *   TensorFlow Lite Python Runtime: Model çıkarımı
    *   PySerial: Arduino/ESP32 ile seri iletişim
*   **Mikrodenetleyici (Atık Kutusu):**
    *   Arduino Uno (veya ESP32)
    *   Arduino IDE (C/C++)
    *   `Stepper.h` (Step motor kontrolü için)
    *   `Servo.h` (Servo motor kontrolü için - isteğe bağlı)
*   **Donanım Bileşenleri:**
    *   Web Kamera
    *   Arduino Uno / ESP32
    *   28BYJ-48 Step Motor
    *   ULN2003A Step Motor Sürücü Kartı
    *   (İsteğe Bağlı) SG90 Servo Motor
    *   Bağlantı kabloları, prototip kutu malzemeleri

## 🚀 Kurulum ve Çalıştırma (Python Script için)

1.  **Gereksinimler:**
    *   Python 3.x
    *   OpenCV (`pip install opencv-python`)
    *   NumPy (`pip install numpy`)
    *   TensorFlow Lite Runtime (`pip install tflite-runtime` veya tam TensorFlow `pip install tensorflow`)
    *   PySerial (`pip install pyserial`)
2.  **Model ve Etiket Dosyaları:**
    *   Eğitilmiş `model.tflite` dosyasını ve `labels.txt` dosyasını Python script'i ile aynı dizine veya argümanla belirttiğiniz yola koyun.
3.  **Arduino/ESP32 Bağlantısı:**
    *   Arduino/ESP32 kartınıza uygun `.ino` kodunu yükleyin.
    *   Kartınızı bilgisayarınıza USB ile bağlayın ve doğru COM portunu (örn. `COM4`) belirleyin.
    *   Arduino IDE Serial Monitor'ünü **kapatın**.
4.  **Script'i Çalıştırma:**
    ```bash
    python kamera_tahmin_serial.py --serial_port SIZIN_COM_PORTUNUZ
    ```
    Diğer argümanlar için:
    ```bash
    python kamera_tahmin_serial.py --help
    ```

##  آینده Geliştirmeler

*   **Mobil Uygulama Entegrasyonu:** Projenin Flutter ile geliştirilen mobil uygulama üzerinden tam kontrolünün sağlanması (Bluetooth BLE ile).
*   **Model Doğruluğunun Artırılması:** Daha fazla ve çeşitli veri ile modelin yeniden eğitilmesi, farklı model mimarilerinin denenmesi.
*   **Farklı Atık Türleri:** Daha fazla atık türünü (örn. farklı plastik çeşitleri, piller) tanıyabilme.
*   **Kutu Doluluk Sensörleri:** Bölmelerin doluluk oranını algılayıp bildirim gönderme.
*   **Daha Sağlam Mekanik Tasarım:** Prototipin daha dayanıklı ve verimli bir mekanik yapıya kavuşturulması.
*   **Enerji Verimliliği:** Güneş paneli gibi alternatif enerji kaynakları ile çalışabilme.

## 🤝 Katkıda Bulunanlar

.

## 📄 Lisans

Bu proje irtengunica altında lisanslanmıştır. Detaylar için `LICENSE` dosyasına bakınız (eğer varsa).

---

Bu proje, çevre bilincini artırmak ve geri dönüşüm süreçlerini kolaylaştırmak amacıyla geliştirilmiştir.

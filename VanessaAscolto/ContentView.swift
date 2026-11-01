import SwiftUI
import AVFoundation

// Registra clip audio da ~2 secondi, una dopo l'altra, e le manda al server di Vanessa
// (lo stesso vanessa_ascolto.py gia' usato dalla pagina web e dall'app Android).
// La modalita' "Background Modes: Audio" (da abilitare in Xcode, vedi istruzioni)
// permette di continuare a registrare anche a schermo bloccato.
class Trasmettitore: NSObject, ObservableObject {
    @Published var inTrasmissione = false
    @Published var messaggio = "Fermato"

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var server = ""
    private var password = ""
    private let session = AVAudioSession.sharedInstance()

    override init() {
        super.init()
        // Se arriva una telefonata (o Siri, o un'altra app audio), iOS toglie il microfono
        // da sola; appena l'interruzione finisce lo riprendiamo qui, cosi' la trasmissione
        // si riprende da sola invece di restare silenziosa.
        NotificationCenter.default.addObserver(
            self, selector: #selector(interruzioneAudio(_:)),
            name: AVAudioSession.interruptionNotification, object: session
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func interruzioneAudio(_ notifica: Notification) {
        guard inTrasmissione,
              let grezzo = notifica.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let tipo = AVAudioSession.InterruptionType(rawValue: grezzo) else { return }
        if tipo == .ended {
            try? session.setActive(true)
        }
    }

    func avvia(server: String, password: String) {
        guard !inTrasmissione else { return }
        let s = server.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = password
        guard !s.isEmpty, !p.isEmpty else {
            messaggio = "Scrivi indirizzo del server e password."
            return
        }
        self.server = s.hasSuffix("/") ? String(s.dropLast()) : s
        self.password = p

        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .allowBluetooth, .defaultToSpeaker])
            try session.setActive(true)
        } catch {
            messaggio = "Impossibile attivare il microfono: \(error.localizedDescription)"
            return
        }

        session.requestRecordPermission { [weak self] concesso in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if concesso {
                    self.inTrasmissione = true
                    self.messaggio = "In trasmissione (anche a schermo bloccato)"
                    self.registraSegmento()
                } else {
                    self.messaggio = "Permesso al microfono negato. Vai in Impostazioni > Vanessa Ascolto e concedilo."
                }
            }
        }
    }

    func ferma() {
        inTrasmissione = false
        timer?.invalidate()
        timer = nil
        recorder?.stop()
        recorder = nil
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        messaggio = "Fermato"
    }

    private func registraSegmento() {
        guard inTrasmissione else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("segmento_\(Int(Date().timeIntervalSince1970 * 1000)).m4a")
        let impostazioni: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
            AVEncoderBitRateKey: 32000
        ]
        do {
            let r = try AVAudioRecorder(url: url, settings: impostazioni)
            recorder = r
            r.record()
        } catch {
            // Non e' riuscita a partire: riprova tra un secondo invece di fermarsi del tutto.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.registraSegmento()
            }
            return
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            self?.chiudiEInvia(url: url)
        }
    }

    private func chiudiEInvia(url: URL) {
        recorder?.stop()
        recorder = nil
        guard inTrasmissione else { return }
        invia(url: url)
        registraSegmento()
    }

    private func invia(url: URL) {
        guard let dati = try? Data(contentsOf: url) else { return }
        try? FileManager.default.removeItem(at: url)
        guard let endpoint = URL(string: server + "/ascolto/invia") else { return }
        var richiesta = URLRequest(url: endpoint)
        richiesta.httpMethod = "POST"
        richiesta.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")
        richiesta.setValue(password, forHTTPHeaderField: "X-Ascolto-Password")
        richiesta.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
        richiesta.timeoutInterval = 8
        URLSession.shared.uploadTask(with: richiesta, from: dati) { [weak self] _, risposta, errore in
            if let http = risposta as? HTTPURLResponse, http.statusCode == 403 {
                DispatchQueue.main.async {
                    self?.messaggio = "Password sbagliata: fermato."
                    self?.ferma()
                }
            }
            // Un errore di rete per una singola clip non e' grave: la prossima puo' farcela.
        }.resume()
    }
}

extension Color {
    // Lo stesso fucsia del logo "VANESSA".
    static let vanessaFucsia = Color(red: 0.86, green: 0.0, blue: 0.55)
}

struct ContentView: View {
    @AppStorage("vanessa_pin") private var pinSalvato = ""
    @State private var sbloccato = false
    @Environment(\.scenePhase) private var fase
    // La trasmissione vive qui, non dentro la schermata sbloccata: cosi' se l'app torna in
    // background e si rimette il blocco PIN, l'audio continua comunque ad essere inviato.
    @StateObject private var tx = Trasmettitore()

    var body: some View {
        ZStack {
            TrasmissioneView(tx: tx)
            if !sbloccato {
                Group {
                    if pinSalvato.isEmpty {
                        ImpostaPinView(pinSalvato: $pinSalvato, sbloccato: $sbloccato)
                    } else {
                        SbloccaView(pinSalvato: pinSalvato, sbloccato: $sbloccato)
                    }
                }
                .background(Color.white.ignoresSafeArea())
                .transition(.opacity)
            }
        }
        .onChange(of: fase) { nuova in
            // Ogni volta che l'app lascia il primo piano (Home, schermo bloccato, altra app),
            // al ritorno richiede di nuovo il PIN - anche se la trasmissione continua lo stesso.
            if nuova != .active {
                sbloccato = false
            }
        }
        .background(Color.white.ignoresSafeArea())
    }
}

// ------------------------------------------------------------- prima apertura: crea il PIN
struct ImpostaPinView: View {
    @Binding var pinSalvato: String
    @Binding var sbloccato: Bool
    @State private var pin = ""
    @State private var conferma = ""
    @State private var errore = ""

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            Text("VANESSA")
                .font(.system(size: 40, weight: .heavy))
                .foregroundColor(.vanessaFucsia)
            Text("Crea un PIN per questa app")
                .foregroundColor(.gray)

            SecureField("Nuovo PIN", text: $pin)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.center)
                .font(.title)
                .frame(maxWidth: 200)

            SecureField("Ripeti il PIN", text: $conferma)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.center)
                .font(.title)
                .frame(maxWidth: 200)

            if !errore.isEmpty {
                Text(errore).foregroundColor(.red).font(.caption)
            }

            Button("Conferma") {
                guard pin.count >= 4 else { errore = "Almeno 4 cifre."; return }
                guard pin == conferma else { errore = "I due PIN non coincidono."; return }
                pinSalvato = pin
                sbloccato = true
            }
            .buttonStyle(.borderedProminent)
            .tint(.vanessaFucsia)

            Spacer()
        }
        .padding(24)
    }
}

// ------------------------------------------------------------- aperture successive: chiede il PIN
struct SbloccaView: View {
    let pinSalvato: String
    @Binding var sbloccato: Bool
    @State private var pin = ""
    @State private var errore = false

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            Text("VANESSA")
                .font(.system(size: 44, weight: .heavy))
                .foregroundColor(.vanessaFucsia)

            SecureField("PIN", text: $pin)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.center)
                .font(.largeTitle)
                .frame(maxWidth: 200)
                .onChange(of: pin) { nuovo in
                    if nuovo.count >= pinSalvato.count {
                        if nuovo == pinSalvato {
                            sbloccato = true
                        } else {
                            errore = true
                            pin = ""
                        }
                    }
                }

            if errore {
                Text("PIN sbagliato").foregroundColor(.red).font(.caption)
            }
            Spacer()
        }
        .padding(24)
    }
}

// ------------------------------------------------------------- schermata vera e propria, dopo lo sblocco
struct TrasmissioneView: View {
    @ObservedObject var tx: Trasmettitore
    @AppStorage("vanessa_server") private var server = ""
    @AppStorage("vanessa_password") private var password = ""

    var body: some View {
        VStack(spacing: 18) {
            Spacer().frame(height: 20)
            Text("VANESSA")
                .font(.system(size: 34, weight: .heavy))
                .foregroundColor(.vanessaFucsia)

            VStack(alignment: .leading, spacing: 4) {
                Text("Indirizzo del server").font(.caption).foregroundColor(.gray)
                TextField("es. http://192.168.1.50:8001", text: $server)
                    .textFieldStyle(.roundedBorder)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .keyboardType(.URL)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Password dell'ascolto").font(.caption).foregroundColor(.gray)
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
            }

            if tx.inTrasmissione {
                Button(action: { tx.ferma() }) {
                    Text("Ferma").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.vanessaFucsia)
                .controlSize(.large)
            } else {
                Button(action: { tx.avvia(server: server, password: password) }) {
                    Text("Inizia a trasmettere").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.vanessaFucsia)
                .controlSize(.large)
            }

            Text(tx.messaggio)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)

            Spacer()
        }
        .padding(24)
    }
}

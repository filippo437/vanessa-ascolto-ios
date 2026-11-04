import SwiftUI
import AVFoundation
import UIKit

// Cattura audio in modo CONTINUO (non piu' a pezzi da 2 secondi) e lo manda in streaming
// vero al server tramite WebSocket - questo e' cio' che elimina i "tick" che si sentivano
// prima: niente piu' file separati da aprire/chiudere, un flusso unico ininterrotto.
// Il motore audio resta sempre acceso mentre l'app e' "armata" (anche se non si sta
// mandando nulla), cosi' iOS considera l'app davvero attiva in background e non la
// sospende piu' per inattivita' come succedeva prima.
class Trasmettitore: NSObject, ObservableObject {
    @Published var inTrasmissione = false   // il telefono e' "armato": microfono acceso, pronto in background
    @Published var inviaAttivo = false      // se l'invio vero e proprio e' acceso, deciso dal server
    @Published var messaggio = "Fermato"

    private let engine = AVAudioEngine()
    private var convertitore: AVAudioConverter?
    private let formatoDestinazione = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true
    )!

    private var wsTask: URLSessionWebSocketTask?
    private var wsSession: URLSession?
    private var riconnettiTimer: Timer?
    private var pollTimer: Timer?
    private var server = ""
    private var password = ""
    private let session = AVAudioSession.sharedInstance()
    private var compitoBackground: UIBackgroundTaskIdentifier = .invalid

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(interruzioneAudio(_:)),
            name: AVAudioSession.interruptionNotification, object: session
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(entrataInBackground),
            name: UIApplication.didEnterBackgroundNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(ritornoInPrimoPiano),
            name: UIApplication.willEnterForegroundNotification, object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func entrataInBackground() {
        guard inTrasmissione else { return }
        compitoBackground = UIApplication.shared.beginBackgroundTask(withName: "vanessa-ascolto") { [weak self] in
            guard let self = self else { return }
            UIApplication.shared.endBackgroundTask(self.compitoBackground)
            self.compitoBackground = .invalid
        }
        try? session.setActive(true)
    }

    @objc private func ritornoInPrimoPiano() {
        if compitoBackground != .invalid {
            UIApplication.shared.endBackgroundTask(compitoBackground)
            compitoBackground = .invalid
        }
    }

    @objc private func interruzioneAudio(_ notifica: Notification) {
        guard inTrasmissione,
              let grezzo = notifica.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let tipo = AVAudioSession.InterruptionType(rawValue: grezzo) else { return }
        if tipo == .ended {
            try? session.setActive(true)
            try? engine.start()
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
                    self.messaggio = "Pronta - in attesa di un comando"
                    self.avviaMotoreAudio()
                    self.controllaAudioRichiesto()
                } else {
                    self.messaggio = "Permesso al microfono negato. Vai in Impostazioni > Vanessa e concedilo."
                }
            }
        }
    }

    func ferma() {
        inTrasmissione = false
        inviaAttivo = false
        pollTimer?.invalidate(); pollTimer = nil
        riconnettiTimer?.invalidate(); riconnettiTimer = nil
        fermaMotoreAudio()
        chiudiWebSocket()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        if compitoBackground != .invalid {
            UIApplication.shared.endBackgroundTask(compitoBackground)
            compitoBackground = .invalid
        }
        messaggio = "Fermato"
    }

    // ---------------- Motore audio: cattura continua, sempre attiva mentre armata ----------------

    private func avviaMotoreAudio() {
        let inputNode = engine.inputNode
        let formatoInput = inputNode.outputFormat(forBus: 0)
        convertitore = AVAudioConverter(from: formatoInput, to: formatoDestinazione)

        inputNode.installTap(onBus: 0, bufferSize: 1600, format: formatoInput) { [weak self] buffer, _ in
            guard let self = self, self.inviaAttivo else { return }
            self.inviaBuffer(buffer, formatoInput: formatoInput)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            DispatchQueue.main.async { self.messaggio = "Errore microfono: \(error.localizedDescription)" }
        }
    }

    private func fermaMotoreAudio() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        convertitore = nil
    }

    private func inviaBuffer(_ buffer: AVAudioPCMBuffer, formatoInput: AVAudioFormat) {
        guard let convertitore = convertitore else { return }
        let capacita = AVAudioFrameCount(formatoDestinazione.sampleRate * Double(buffer.frameLength) / formatoInput.sampleRate) + 16
        guard let uscita = AVAudioPCMBuffer(pcmFormat: formatoDestinazione, frameCapacity: capacita) else { return }

        var consumato = false
        var erroreConversione: NSError?
        convertitore.convert(to: uscita, error: &erroreConversione) { _, stato in
            if consumato {
                stato.pointee = .noDataNow
                return nil
            }
            consumato = true
            stato.pointee = .haveData
            return buffer
        }
        guard erroreConversione == nil, let dati = uscita.int16ChannelData else { return }
        let bytes = Data(bytes: dati[0], count: Int(uscita.frameLength) * 2)
        inviaSuWebSocket(bytes)
    }

    // ---------------- WebSocket: connessione persistente verso il server ----------------

    private func apriWebSocketSeServe() {
        guard wsTask == nil else { return }
        let base = server
            .replacingOccurrences(of: "https://", with: "wss://")
            .replacingOccurrences(of: "http://", with: "ws://")
        guard let encodedPw = password.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: base + "/ascolto/ws?ruolo=trasmetti&pw=" + encodedPw) else { return }

        let s = URLSession(configuration: .default)
        wsSession = s
        let task = s.webSocketTask(with: url)
        wsTask = task
        ascoltaChiusura(task)
        task.resume()
    }

    private func ascoltaChiusura(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] risultato in
            guard let self = self else { return }
            switch risultato {
            case .failure:
                if self.wsTask === task { self.wsTask = nil }
                self.pianificaRiconnessione()
            case .success:
                if self.wsTask === task {
                    self.ascoltaChiusura(task)
                }
            }
        }
    }

    private func pianificaRiconnessione() {
        guard inviaAttivo, inTrasmissione else { return }
        riconnettiTimer?.invalidate()
        riconnettiTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            self?.apriWebSocketSeServe()
        }
    }

    private func chiudiWebSocket() {
        wsTask?.cancel(with: .goingAway, reason: nil)
        wsTask = nil
        wsSession = nil
    }

    private func inviaSuWebSocket(_ dati: Data) {
        guard inviaAttivo else { return }
        if wsTask == nil { apriWebSocketSeServe() }
        wsTask?.send(.data(dati)) { [weak self] errore in
            if errore != nil {
                self?.wsTask = nil
                self?.pianificaRiconnessione()
            }
        }
    }

    // ---------------- Controllo acceso/spento, deciso dal server ----------------

    private func controllaAudioRichiesto() {
        guard inTrasmissione, let endpoint = URL(string: server + "/ascolto/audio_stato") else { return }
        var richiesta = URLRequest(url: endpoint)
        richiesta.setValue(password, forHTTPHeaderField: "X-Ascolto-Password")
        richiesta.timeoutInterval = 6
        URLSession.shared.dataTask(with: richiesta) { [weak self] dati, _, _ in
            guard let self = self, let dati = dati,
                  let risposta = try? JSONSerialization.jsonObject(with: dati) as? [String: Any],
                  let acceso = risposta["on"] as? Bool else { return }
            DispatchQueue.main.async {
                guard self.inTrasmissione else { return }
                let primaEraAttivo = self.inviaAttivo
                self.inviaAttivo = acceso
                self.messaggio = acceso ? "In trasmissione (anche a schermo bloccato)" : "Pronta - in attesa di un comando"
                if acceso && !primaEraAttivo {
                    self.apriWebSocketSeServe()
                } else if !acceso && primaEraAttivo {
                    self.chiudiWebSocket()
                }
            }
        }.resume()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            self?.controllaAudioRichiesto()
        }
    }
}

extension Color {
    static let vanessaFucsia = Color(red: 0.90, green: 0.0, blue: 0.49)
    static let vanessaNero = Color(red: 0.04, green: 0.04, blue: 0.04)
}

struct ContentView: View {
    @AppStorage("vanessa_pin") private var pinSalvato = ""
    @AppStorage("vanessa_server") private var server = ""
    @AppStorage("vanessa_password") private var password = ""
    @State private var sbloccato = false
    @Environment(\.scenePhase) private var fase
    @StateObject private var tx = Trasmettitore()

    private var configuratoCompleto: Bool {
        !server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty
    }

    var body: some View {
        ZStack {
            Color.vanessaNero.ignoresSafeArea()

            if configuratoCompleto {
                TrasmissioneView(tx: tx, server: server, password: password)
            }

            if !sbloccato {
                Group {
                    if pinSalvato.isEmpty {
                        ImpostaPinView(pinSalvato: $pinSalvato, sbloccato: $sbloccato)
                    } else {
                        SbloccaView(pinSalvato: pinSalvato, sbloccato: $sbloccato)
                    }
                }
                .background(Color.vanessaNero.ignoresSafeArea())
                .transition(.opacity)
            } else if !configuratoCompleto {
                ConfiguraServerView(server: $server, password: $password)
                    .background(Color.vanessaNero.ignoresSafeArea())
            }
        }
        .onChange(of: fase) { nuova in
            if nuova != .active {
                sbloccato = false
            }
        }
    }
}

// ------------------------------------------------------------- tastierino numerico condiviso (stile PIN)
struct TastieraPin: View {
    let azionePremuto: (String) -> Void

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 18) {
            ForEach(1...9, id: \.self) { numero in
                tastoNumero("\(numero)")
            }
            Color.clear.frame(height: 50)
            tastoNumero("0")
            tastoBackspace
        }
        .frame(maxWidth: 220)
    }

    private func tastoNumero(_ testo: String) -> some View {
        Button(action: { azionePremuto(testo) }) {
            Text(testo)
                .font(.system(size: 26, weight: .regular))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, minHeight: 50)
        }
        .buttonStyle(.plain)
    }

    private var tastoBackspace: some View {
        Button(action: { azionePremuto("backspace") }) {
            Image(systemName: "delete.left")
                .font(.system(size: 22))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, minHeight: 50)
        }
        .buttonStyle(.plain)
    }
}

// ------------------------------------------------------------- pallini che mostrano quante cifre del PIN sono state inserite
struct PinPallini: View {
    let lunghezzaAttuale: Int
    let lunghezzaTotale: Int

    var body: some View {
        HStack(spacing: 14) {
            ForEach(0..<lunghezzaTotale, id: \.self) { indice in
                Circle()
                    .strokeBorder(Color.vanessaFucsia, lineWidth: 2)
                    .background(
                        Circle().fill(indice < lunghezzaAttuale ? Color.vanessaFucsia : Color.clear)
                    )
                    .frame(width: 16, height: 16)
            }
        }
    }
}

// ------------------------------------------------------------- prima apertura: crea il PIN
struct ImpostaPinView: View {
    @Binding var pinSalvato: String
    @Binding var sbloccato: Bool
    @State private var pin = ""
    @State private var primoPin = ""
    @State private var fase = 1
    @State private var errore = ""

    private let lunghezza = 4

    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            Text("VANESSA")
                .font(.system(size: 32, weight: .heavy))
                .foregroundColor(.white)
            Text(fase == 1 ? "Crea un PIN" : "Ripeti il PIN")
                .foregroundColor(.gray)
                .font(.footnote)

            PinPallini(lunghezzaAttuale: pin.count, lunghezzaTotale: lunghezza)
                .padding(.vertical, 24)

            if !errore.isEmpty {
                Text(errore).foregroundColor(.red).font(.caption)
            }

            TastieraPin { tasto in gestisciTasto(tasto) }

            Spacer()
        }
        .padding(24)
    }

    private func gestisciTasto(_ tasto: String) {
        errore = ""
        if tasto == "backspace" {
            if !pin.isEmpty { pin.removeLast() }
            return
        }
        guard pin.count < lunghezza else { return }
        pin += tasto
        guard pin.count == lunghezza else { return }

        if fase == 1 {
            primoPin = pin
            pin = ""
            fase = 2
        } else {
            if pin == primoPin {
                pinSalvato = pin
                sbloccato = true
            } else {
                errore = "I PIN non coincidono, riprova."
                pin = ""
                fase = 1
                primoPin = ""
            }
        }
    }
}

// ------------------------------------------------------------- aperture successive: chiede il PIN
struct SbloccaView: View {
    let pinSalvato: String
    @Binding var sbloccato: Bool
    @State private var pin = ""
    @State private var errore = false

    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            Text("VANESSA")
                .font(.system(size: 32, weight: .heavy))
                .foregroundColor(.white)
            Text("Inserisci il PIN")
                .foregroundColor(.gray)
                .font(.footnote)

            PinPallini(lunghezzaAttuale: pin.count, lunghezzaTotale: pinSalvato.count)
                .padding(.vertical, 24)

            if errore {
                Text("PIN sbagliato").foregroundColor(.red).font(.caption)
            }

            TastieraPin { tasto in gestisciTasto(tasto) }

            Spacer()
        }
        .padding(24)
    }

    private func gestisciTasto(_ tasto: String) {
        if tasto == "backspace" {
            if !pin.isEmpty { pin.removeLast() }
            errore = false
            return
        }
        guard pin.count < pinSalvato.count else { return }
        pin += tasto
        if pin.count == pinSalvato.count {
            if pin == pinSalvato {
                sbloccato = true
            } else {
                errore = true
                pin = ""
            }
        }
    }
}

// ------------------------------------------------------------- configurazione iniziale (una tantum): indirizzo server + password
struct ConfiguraServerView: View {
    @Binding var server: String
    @Binding var password: String
    @State private var serverTemp = ""
    @State private var passwordTemp = ""

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Text("VANESSA")
                .font(.system(size: 32, weight: .heavy))
                .foregroundColor(.white)
            Text("Configurazione iniziale")
                .foregroundColor(.gray)
                .font(.footnote)

            VStack(alignment: .leading, spacing: 4) {
                Text("Indirizzo del server").font(.caption).foregroundColor(.gray)
                TextField("es. http://2.29.124.5:8080", text: $serverTemp)
                    .textFieldStyle(.roundedBorder)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .keyboardType(.URL)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Password").font(.caption).foregroundColor(.gray)
                SecureField("Password", text: $passwordTemp)
                    .textFieldStyle(.roundedBorder)
            }

            Button("Salva") {
                server = serverTemp.trimmingCharacters(in: .whitespacesAndNewlines)
                password = passwordTemp
            }
            .buttonStyle(.borderedProminent)
            .tint(.vanessaFucsia)
            .disabled(serverTemp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || passwordTemp.isEmpty)

            Text("Questa schermata appare solo una volta.")
                .foregroundColor(.gray)
                .font(.caption2)

            Spacer()
        }
        .padding(24)
    }
}

// ------------------------------------------------------------- schermata vera e propria, dopo lo sblocco: niente campi in vista, solo stato
struct TrasmissioneView: View {
    @ObservedObject var tx: Trasmettitore
    let server: String
    let password: String

    var body: some View {
        VStack(spacing: 14) {
            Spacer().frame(height: 30)
            Text("VANESSA")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
                .opacity(0.8)

            sfera
                .padding(.vertical, 10)

            Text(testoStato)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(tx.inviaAttivo ? .green : .gray)

            if tx.inTrasmissione {
                Button(action: { tx.ferma() }) {
                    Text("BLOCK")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .foregroundColor(.vanessaFucsia)
                .overlay(Capsule().stroke(Color.vanessaFucsia, lineWidth: 1.5))
                .padding(.top, 20)
            } else {
                Button(action: { tx.avvia(server: server, password: password) }) {
                    Text("Attiva questo telefono")
                        .frame(maxWidth: 220)
                }
                .buttonStyle(.borderedProminent)
                .tint(.vanessaFucsia)
                .controlSize(.large)
                .padding(.top, 20)
            }

            if !tx.messaggio.isEmpty {
                Text(tx.messaggio)
                    .foregroundColor(.gray)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)
            }

            Spacer()
        }
        .padding(24)
    }

    private var testoStato: String {
        if tx.inviaAttivo { return "● Trasmissione attiva" }
        if tx.inTrasmissione { return "Pronta, in attesa" }
        return "Non attiva"
    }

    private var sfera: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: tx.inviaAttivo
                        ? [Color(red: 1.0, green: 0.36, blue: 0.70), Color.vanessaFucsia]
                        : [Color(white: 0.25), Color(white: 0.12)],
                    center: UnitPoint(x: 0.35, y: 0.3),
                    startRadius: 4, endRadius: 110
                )
            )
            .frame(width: 160, height: 160)
            .shadow(color: tx.inviaAttivo ? Color.vanessaFucsia.opacity(0.4) : .clear, radius: 40)
    }
}

import SwiftUI
import AVFoundation
import UIKit
import UserNotifications

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
    @Published var erroreStreaming = ""   // dettaglio tecnico se il WebSocket non riesce a collegarsi, mostrato in chiaro

    private let engine = AVAudioEngine()
    private var convertitore: AVAudioConverter?
    private let formatoDestinazione = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true
    )!

    private var wsTask: URLSessionWebSocketTask?
    private var wsSession: URLSession?
    private var riconnettiTimer: Timer?
    private var pollTimer: Timer?
    private var timerStatoDispositivo: Timer?
    private var timerSorveglianza: Timer?
    private var ultimoInvioRiuscito: Date?
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
        NotificationCenter.default.addObserver(
            self, selector: #selector(stoChiudendo),
            name: UIApplication.willTerminateNotification, object: nil
        )
        // iOS puo' riconfigurare l'hardware audio in qualsiasi momento (anche senza
        // una vera interruzione): se succede, il motore smette di dare buffer senza
        // nessun errore visibile. Questi due osservatori ricostruiscono tutto quando capita.
        NotificationCenter.default.addObserver(
            self, selector: #selector(configurazioneAudioCambiata),
            name: .AVAudioEngineConfigurationChange, object: engine
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(percorsoAudioCambiato(_:)),
            name: AVAudioSession.routeChangeNotification, object: session
        )
    }

    // Tentativo "ultimo respiro": se iOS fa in tempo ad avvisarci prima di chiudere
    // l'app (non sempre succede, specialmente se il sistema la termina in background
    // per motivi suoi), mandiamo subito un ultimo aggiornamento al server. Non e'
    // garantito, ma quando funziona rende la disconnessione visibile prima.
    @objc private func stoChiudendo() {
        guard inTrasmissione else { return }
        inviaStatoDispositivo()
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
        // Appena si torna a vedere l'app (anche con un tocco veloce sull'icona), il
        // promemoria della chiamata non serve piu': lo togliamo subito.
        annullaPromemoriaRiapertura()
        // Controllo di sicurezza: se il motore non sta davvero girando (es. dopo una
        // telefonata che ha lasciato tutto bloccato), lo ricostruiamo subito, senza
        // aspettare il cane da guardia.
        guard inTrasmissione, !engine.isRunning else { return }
        riprovaRiattivazione(tentativiRimasti: 5)
    }

    @objc private func interruzioneAudio(_ notifica: Notification) {
        guard inTrasmissione,
              let grezzo = notifica.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let tipo = AVAudioSession.InterruptionType(rawValue: grezzo) else { return }
        if tipo == .began {
            // Una telefonata (normale o VoIP come WhatsApp) sta per togliere il microfono
            // all'app. Se la chiamata dura tanto e il telefono resta in background, iOS
            // potrebbe chiudere del tutto l'app: in quel caso il ramo ".ended" qui sotto
            // non girerebbe mai (il processo sarebbe morto). Questo promemoria "di riserva"
            // serve solo per quel caso estremo, quindi ha un ritardo lungo apposta - nella
            // grande maggioranza dei casi verra' cancellato subito dal recupero riuscito,
            // senza mai comparire sullo schermo.
            pianificaPromemoriaRiserva()
        } else if tipo == .ended {
            let opzioniGrezze = notifica.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            let dovrebberiprendere = opzioniGrezze.map { AVAudioSession.InterruptionOptions(rawValue: $0).contains(.shouldResume) } ?? true
            if dovrebberiprendere {
                // La chiamata e' finita davvero ORA e il nostro codice e' vivo (altrimenti
                // questo ramo non girerebbe). Il promemoria "di riserva" non serve piu':
                // lo togliamo e proviamo subito il recupero vero, rapido.
                annullaPromemoriaRiserva()
                riprovaRiattivazione(tentativiRimasti: 5)
                // Diamo al recupero una manciata di secondi (i primi tentativi sono quasi
                // immediati) e solo SE a quel punto non e' ancora ripartito avvisiamo subito.
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                    guard let self = self, self.inTrasmissione, !self.engine.isRunning else { return }
                    self.avvisaSubitoNonRipartita()
                }
            }
        }
    }

    // ---------------- Promemoria locale: unica rete di sicurezza possibile senza account Apple a pagamento ----------------
    // Le notifiche push "vere" (che risveglierebbero l'app da sola, da remoto) richiedono
    // un account Apple Developer a pagamento. Senza quello, la cosa piu' vicina che possiamo
    // fare e' un promemoria locale (nessun server, nessun account speciale) che avvisa la
    // persona di riaprire l'app con un tocco - il recupero poi e' automatico e istantaneo.

    private static let idPromemoria = "vanessa_promemoria_riapertura"

    // Promemoria "di riserva": parte con un ritardo lungo (copre anche il caso in cui
    // l'app venga chiusa del tutto durante la chiamata) ma viene quasi sempre cancellato
    // in pochi secondi dal recupero riuscito, prima ancora di arrivare a comparire.
    private func pianificaPromemoriaRiserva() {
        let centro = UNUserNotificationCenter.current()
        centro.removePendingNotificationRequests(withIdentifiers: [Self.idPromemoria])

        let contenuto = UNMutableNotificationContent()
        contenuto.title = "Vanessa si e' fermata"
        contenuto.body = "La chiamata ha interrotto l'ascolto. Apri Vanessa un istante per farla ripartire da sola."
        contenuto.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 90.0, repeats: false)
        let richiesta = UNNotificationRequest(identifier: Self.idPromemoria, content: contenuto, trigger: trigger)
        centro.add(richiesta)
    }

    private func annullaPromemoriaRiserva() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.idPromemoria])
    }

    // Avviso immediato (pochi secondi dopo la fine della chiamata): usato solo quando il
    // recupero automatico non e' bastato da solo, quindi serve davvero un tocco umano.
    private func avvisaSubitoNonRipartita() {
        let centro = UNUserNotificationCenter.current()
        centro.removePendingNotificationRequests(withIdentifiers: [Self.idPromemoria])

        let contenuto = UNMutableNotificationContent()
        contenuto.title = "Vanessa si e' fermata"
        contenuto.body = "La chiamata e' finita ma l'ascolto non e' ripartito da solo. Apri Vanessa un istante."
        contenuto.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.5, repeats: false)
        let richiesta = UNNotificationRequest(identifier: Self.idPromemoria, content: contenuto, trigger: trigger)
        centro.add(richiesta)
    }

    private func annullaPromemoriaRiapertura() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.idPromemoria])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.idPromemoria])
    }

    // Riprova a riattivare sessione + motore audio con piccoli ritardi crescenti,
    // finche' non funziona davvero (engine.isRunning) o finiscono i tentativi.
    // Questo e' cio' che elimina il "si blocca e non riparte piu'" dopo una chiamata.
    private func riprovaRiattivazione(tentativiRimasti: Int) {
        guard inTrasmissione, !engine.isRunning, tentativiRimasti > 0 else { return }
        ricostruisciMotoreAudio()
        guard inTrasmissione, !engine.isRunning else { return }
        let attesa = Double(6 - tentativiRimasti) * 0.6 + 0.4
        DispatchQueue.main.asyncAfter(deadline: .now() + attesa) { [weak self] in
            self?.riprovaRiattivazione(tentativiRimasti: tentativiRimasti - 1)
        }
    }

    // Chiamati quando iOS cambia qualcosa nell'hardware audio sotto banco (es. riassegna
    // il microfono, cambia dispositivo Bluetooth, o altro): senza questo, il motore resta
    // "in esecuzione" ma smette di produrre buffer, in modo del tutto silenzioso.
    @objc private func configurazioneAudioCambiata() {
        guard inTrasmissione else { return }
        DispatchQueue.main.async { [weak self] in self?.ricostruisciMotoreAudio() }
    }

    @objc private func percorsoAudioCambiato(_ notifica: Notification) {
        guard inTrasmissione else { return }
        DispatchQueue.main.async { [weak self] in self?.ricostruisciMotoreAudio() }
    }

    // Ricostruzione completa e sicura del motore audio: toglie il tap vecchio (che
    // potrebbe avere un formato ormai non valido), riattiva la sessione e reinstalla
    // tutto da zero. E' la base sia delle notifiche di sistema sopra, sia del cane da
    // guardia qui sotto.
    private func ricostruisciMotoreAudio() {
        guard inTrasmissione else { return }
        fermaMotoreAudio()
        // Dopo una telefonata iOS a volte "dimentica" la categoria della sessione:
        // la impostiamo di nuovo esplicitamente prima di riattivare, non solo setActive.
        try? session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .allowBluetooth, .defaultToSpeaker])
        try? session.setActive(true)
        avviaMotoreAudio()
    }

    // ---------------- Cane da guardia: si accorge da solo se l'invio si e' bloccato ----------------
    // Copre qualunque causa di blocco silenzioso (anche una non ancora prevista sopra):
    // se dovremmo star mandando audio ma da troppo tempo non ci riusciamo, ricostruisce
    // tutto - motore audio e connessione - senza bisogno di intervento manuale.

    private func avviaSorveglianza() {
        timerSorveglianza?.invalidate()
        timerSorveglianza = Timer.scheduledTimer(withTimeInterval: 20.0, repeats: true) { [weak self] _ in
            self?.controllaSalute()
        }
    }

    private func controllaSalute() {
        guard inTrasmissione, inviaAttivo else { return }
        let secondiDaUltimoInvio = ultimoInvioRiuscito.map { Date().timeIntervalSince($0) } ?? 999
        guard secondiDaUltimoInvio > 45 else { return }

        DispatchQueue.main.async {
            self.erroreStreaming = "Invio bloccato da \(Int(secondiDaUltimoInvio))s, ricostruzione automatica in corso\u{2026}"
        }
        ricostruisciMotoreAudio()
        chiudiWebSocket()
        apriWebSocketSeServe()
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

        // L'attivazione della sessione audio puo', in certi momenti (es. appena dopo
        // l'apertura dell'app), metterci piu' di un istante a rispondere: farla sul
        // thread principale blocca tutta l'interfaccia nel frattempo (anche il PIN
        // sembra "congelarsi"). La spostiamo quindi su un thread secondario.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                try self.session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .allowBluetooth, .defaultToSpeaker])
                try self.session.setActive(true)
            } catch {
                DispatchQueue.main.async {
                    self.messaggio = "Impossibile attivare il microfono: \(error.localizedDescription)"
                }
                return
            }
            self.session.requestRecordPermission { [weak self] concesso in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    if concesso {
                    self.inTrasmissione = true
                    self.messaggio = "Pronta - in attesa di un comando"
                    self.avviaMotoreAudio()
                    self.controllaAudioRichiesto()
                    self.avviaInvioStatoDispositivo()
                    self.avviaSorveglianza()
                    // Permesso per il promemoria locale (vedi piu' sotto): serve per
                    // poter avvisare di riaprire l'app se una chiamata la blocca.
                    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
                    } else {
                        self.messaggio = "Permesso al microfono negato. Vai in Impostazioni > Vanessa e concedilo."
                    }
                }
            }
        }
    }

    func ferma() {
        inTrasmissione = false
        inviaAttivo = false
        pollTimer?.invalidate(); pollTimer = nil
        riconnettiTimer?.invalidate(); riconnettiTimer = nil
        timerStatoDispositivo?.invalidate(); timerStatoDispositivo = nil
        timerSorveglianza?.invalidate(); timerSorveglianza = nil
        ultimoInvioRiuscito = nil
        erroreStreaming = ""
        fermaMotoreAudio()
        chiudiWebSocket()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        if compitoBackground != .invalid {
            UIApplication.shared.endBackgroundTask(compitoBackground)
            compitoBackground = .invalid
        }
        annullaPromemoriaRiapertura()
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
              let url = URL(string: base + "/ascolto/ws?ruolo=trasmetti&pw=" + encodedPw) else {
            DispatchQueue.main.async { self.erroreStreaming = "Indirizzo del server non valido per lo streaming." }
            return
        }

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
            case .failure(let errore):
                if self.wsTask === task { self.wsTask = nil }
                DispatchQueue.main.async {
                    self.erroreStreaming = "Streaming non connesso: \((errore as NSError).localizedDescription)"
                }
                self.pianificaRiconnessione()
            case .success:
                if self.wsTask === task {
                    DispatchQueue.main.async { self.erroreStreaming = "" }
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
            } else {
                self?.ultimoInvioRiuscito = Date()
            }
        }
    }

    // ---------------- Stato del telefono (batteria) mandato periodicamente al server ----------------
    // Il segnale cellulare non e' leggibile dalle app da qualche anno (Apple lo ha bloccato
    // per privacy), quindi mandiamo solo la batteria: e' quella che la dashboard mostra.

    private func avviaInvioStatoDispositivo() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        inviaStatoDispositivo()
        timerStatoDispositivo = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.inviaStatoDispositivo()
        }
    }

    private func inviaStatoDispositivo() {
        guard inTrasmissione, let endpoint = URL(string: server + "/ascolto/stato_dispositivo") else { return }
        let livello = UIDevice.current.batteryLevel
        let percentuale = livello >= 0 ? Int(livello * 100) : nil

        var richiesta = URLRequest(url: endpoint)
        richiesta.httpMethod = "POST"
        richiesta.setValue(password, forHTTPHeaderField: "X-Ascolto-Password")
        richiesta.setValue("application/json", forHTTPHeaderField: "Content-Type")
        richiesta.timeoutInterval = 6
        var corpo: [String: Any] = [:]
        if let percentuale = percentuale { corpo["batteria"] = percentuale }
        richiesta.httpBody = try? JSONSerialization.data(withJSONObject: corpo)
        URLSession.shared.dataTask(with: richiesta).resume()
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
                    self.ultimoInvioRiuscito = Date()
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
    @AppStorage("vanessa_server") private var server = ""
    @AppStorage("vanessa_password") private var password = ""
    @StateObject private var tx = Trasmettitore()

    private var configuratoCompleto: Bool {
        !server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty
    }

    var body: some View {
        ZStack {
            Color.vanessaNero.ignoresSafeArea()

            if configuratoCompleto {
                TrasmissioneView(tx: tx, server: server, password: password)
            } else {
                ConfiguraServerView(server: $server, password: $password)
                    .background(Color.vanessaNero.ignoresSafeArea())
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

            if !tx.erroreStreaming.isEmpty {
                Text(tx.erroreStreaming)
                    .foregroundColor(.red)
                    .font(.caption2)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
                    .padding(.horizontal, 12)
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

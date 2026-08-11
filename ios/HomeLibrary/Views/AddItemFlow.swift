import SwiftData
import SwiftUI

struct AddItemFlow: View {
    private enum Step {
        case scanner
        case form
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var step: Step
    @State private var publicationType: PublicationType = .book
    @State private var title = ""
    @State private var subtitle = ""
    @State private var authors = ""
    @State private var language = "pl"
    @State private var publisher = ""
    @State private var publicationYear = ""
    @State private var isbn13 = ""
    @State private var issn = ""
    @State private var ean = ""
    @State private var barcode = ""
    @State private var issueNumber = ""
    @State private var issueVolume = ""
    @State private var issueDate = ""
    @State private var locationPath = ""
    @State private var notes = ""
    @State private var metadataSource = "manual"
    @State private var validationMessage: String?

    init(startWithScanner: Bool) {
        _step = State(initialValue: startWithScanner ? .scanner : .form)
    }

    var body: some View {
        NavigationStack {
            switch step {
            case .scanner:
                ScannerStep { value, cameFromCamera in
                    apply(identifier: value)
                    metadataSource = cameFromCamera ? "scan" : "manual"
                    step = .form
                }
                .navigationTitle("Skanuj kod")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Anuluj") { dismiss() }
                    }
                }

            case .form:
                form
                    .navigationTitle(metadataSource == "scan" ? "Sprawdź publikację" : "Nowa publikacja")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Anuluj") { dismiss() }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Zapisz", action: save)
                                .fontWeight(.semibold)
                                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
            }
        }
        .interactiveDismissDisabled(step == .form && hasEnteredData)
        .alert("Sprawdź dane", isPresented: Binding(
            get: { validationMessage != nil },
            set: { if !$0 { validationMessage = nil } }
        )) {
            Button("OK", role: .cancel) { validationMessage = nil }
        } message: {
            Text(validationMessage ?? "")
        }
    }

    private var form: some View {
        Form {
            Section("Rodzaj") {
                Picker("Rodzaj publikacji", selection: $publicationType) {
                    ForEach(PublicationType.allCases) { type in
                        Label(type.label, systemImage: type.symbolName).tag(type)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Opis") {
                TextField("Tytuł", text: $title)
                TextField("Podtytuł", text: $subtitle)
                TextField("Autorzy (oddziel średnikiem)", text: $authors, axis: .vertical)
                TextField("Wydawca", text: $publisher)
                HStack {
                    TextField("Rok wydania", text: $publicationYear)
                        .keyboardType(.numberPad)
                    TextField("Język, np. pl", text: $language)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }

            Section("Identyfikatory") {
                TextField("ISBN-13", text: $isbn13)
                    .keyboardType(.numbersAndPunctuation)
                if publicationType == .periodical {
                    TextField("ISSN", text: $issn)
                        .keyboardType(.numbersAndPunctuation)
                }
                TextField("EAN", text: $ean)
                    .keyboardType(.numberPad)
                if !barcode.isEmpty {
                    LabeledContent("Zeskanowany kod", value: barcode)
                        .font(.caption)
                }
            }

            if publicationType == .periodical {
                Section {
                    TextField("Numer, np. 8/2026", text: $issueNumber)
                    TextField("Rocznik / tom", text: $issueVolume)
                    TextField("Data, np. 2026-08", text: $issueDate)
                } header: {
                    Text("Konkretny numer")
                } footer: {
                    Text("ISSN opisuje tytuł ciągły, dlatego numer lub datę egzemplarza zapisujemy osobno.")
                }
            }

            Section {
                TextField("Dom / Pokój / Regał / Półka", text: $locationPath)
                    .textInputAutocapitalization(.words)
                TextField("Notatki", text: $notes, axis: .vertical)
                    .lineLimit(2...5)
            } header: {
                Text("Fizyczny egzemplarz")
            } footer: {
                Text("Ukośniki tworzą hierarchię lokalizacji, np. Dom / Gabinet / Regał A / Półka 2.")
            }
        }
    }

    private var hasEnteredData: Bool {
        !title.isEmpty || !authors.isEmpty || !barcode.isEmpty || !locationPath.isEmpty
    }

    private func apply(identifier rawValue: String) {
        let parsed = PublicationIdentifierParser.parse(rawValue)
        barcode = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)

        switch parsed.kind {
        case .isbn10 where parsed.isValid,
             .isbn13 where parsed.isValid:
            isbn13 = parsed.isbn13 ?? parsed.normalized
            ean = parsed.isbn13 ?? ""
        case .ean13 where parsed.isValid:
            ean = parsed.normalized
        case .upce:
            ean = parsed.normalized
        default:
            break
        }
    }

    private func save() {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else {
            validationMessage = "Tytuł jest wymagany."
            return
        }

        let cleanYear = publicationYear.trimmingCharacters(in: .whitespacesAndNewlines)
        let year: Int?
        if cleanYear.isEmpty {
            year = nil
        } else if let value = Int(cleanYear), (1...9999).contains(value) {
            year = value
        } else {
            validationMessage = "Rok wydania powinien być liczbą od 1 do 9999."
            return
        }

        var normalizedISBN = isbn13.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedISBN.isEmpty {
            let parsed = PublicationIdentifierParser.parse(normalizedISBN)
            guard parsed.isValid, parsed.kind == .isbn10 || parsed.kind == .isbn13 else {
                validationMessage = "ISBN ma nieprawidłową długość lub cyfrę kontrolną."
                return
            }
            normalizedISBN = parsed.isbn13 ?? parsed.normalized
        }

        var normalizedEAN = ean.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedEAN.isEmpty {
            let parsed = PublicationIdentifierParser.parse(normalizedEAN)
            if parsed.kind == .ean13 || parsed.kind == .isbn13 {
                guard parsed.isValid else {
                    validationMessage = "EAN-13 ma nieprawidłową cyfrę kontrolną."
                    return
                }
                normalizedEAN = parsed.normalized
            }
        }

        let now = Date.now
        let publication = Publication(
            type: publicationType,
            title: cleanTitle,
            subtitle: subtitle.trimmingCharacters(in: .whitespacesAndNewlines),
            authorsText: authors.trimmingCharacters(in: .whitespacesAndNewlines),
            language: language.trimmingCharacters(in: .whitespacesAndNewlines),
            publisher: publisher.trimmingCharacters(in: .whitespacesAndNewlines),
            publicationYear: year,
            isbn13: normalizedISBN,
            issn: issn.trimmingCharacters(in: .whitespacesAndNewlines),
            ean: normalizedEAN,
            barcode: barcode,
            issueNumber: issueNumber.trimmingCharacters(in: .whitespacesAndNewlines),
            issueVolume: issueVolume.trimmingCharacters(in: .whitespacesAndNewlines),
            issueDate: issueDate.trimmingCharacters(in: .whitespacesAndNewlines),
            metadataSource: metadataSource,
            createdAt: now,
            updatedAt: now
        )
        let item = OwnedItem(
            publication: publication,
            locationPathText: locationPath.trimmingCharacters(in: .whitespacesAndNewlines),
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
            addedAt: now,
            updatedAt: now
        )

        modelContext.insert(publication)
        modelContext.insert(item)
        do {
            try modelContext.save()
            dismiss()
        } catch {
            validationMessage = "Nie udało się zapisać publikacji: \(error.localizedDescription)"
        }
    }
}

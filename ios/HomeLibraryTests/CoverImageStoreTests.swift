import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import HomeLibrary

final class CoverImageStoreTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    func testNetworkLoadSanitizesDownsamplesAndPersistsWithoutEXIF() async throws {
        let input = try Self.makeImageData(
            width: 1_800,
            height: 900,
            typeIdentifier: UTType.jpeg.identifier,
            seed: 1,
            includesEXIF: true
        )
        let transport = StubCoverImageTransport(responses: [
            .http(status: 200, mimeType: "image/jpeg", data: input)
        ])
        let directory = makeTemporaryDirectory()
        let store = try CoverImageStore(transport: transport, cacheDirectory: directory)
        let url = Self.coverURL("sanitized")

        let loadedPayload = try await store.image(for: url)
        let payload = try XCTUnwrap(loadedPayload)

        XCTAssertEqual(payload.mimeType, "image/jpeg")
        let source = try XCTUnwrap(CGImageSourceCreateWithData(payload.data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.jpeg.identifier)
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
        XCTAssertEqual((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, 1_200)
        XCTAssertEqual((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, 600)
        XCTAssertNil(properties[kCGImagePropertyExifDictionary])
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary])

        let cached = try await store.cachedImage(for: url)
        XCTAssertEqual(cached, payload)
        let firstTransportCalls = await transport.callCount
        XCTAssertEqual(firstTransportCalls, 1)

        let resourceValues = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(resourceValues.isExcludedFromBackup, true)

        let secondTransport = StubCoverImageTransport(responses: [
            .http(status: 500, mimeType: "text/plain", data: Data())
        ])
        let restartedStore = try CoverImageStore(
            transport: secondTransport,
            cacheDirectory: directory
        )
        let restartedPayload = try await restartedStore.cachedImage(for: url)
        let secondTransportCalls = await secondTransport.callCount
        XCTAssertEqual(restartedPayload, payload)
        XCTAssertEqual(secondTransportCalls, 0)
    }

    func testCachedImageNeverUsesNetworkOnMiss() async throws {
        let transport = StubCoverImageTransport(responses: [
            .http(
                status: 200,
                mimeType: "image/jpeg",
                data: try Self.makeImageData(
                    width: 40,
                    height: 60,
                    typeIdentifier: UTType.jpeg.identifier,
                    seed: 2
                )
            )
        ])
        let store = try CoverImageStore(
            transport: transport,
            cacheDirectory: makeTemporaryDirectory()
        )

        let cached = try await store.cachedImage(for: Self.coverURL("disk-only"))
        let calls = await transport.callCount
        XCTAssertNil(cached)
        XCTAssertEqual(calls, 0)
    }

    func testRejectsNonHTTPSAndHostsOutsideAllowlistBeforeTransport() async throws {
        let transport = StubCoverImageTransport(responses: [
            .http(status: 404, mimeType: nil, data: Data())
        ])
        let store = try CoverImageStore(
            transport: transport,
            cacheDirectory: makeTemporaryDirectory()
        )
        let rejected = [
            URL(string: "http://covers.openlibrary.org/b/id/1-M.jpg")!,
            URL(string: "https://openlibrary.org/b/id/1-M.jpg")!,
            URL(string: "https://covers.openlibrary.org.evil.example/b/id/1-M.jpg")!,
            URL(string: "https://user@covers.openlibrary.org/b/id/1-M.jpg")!,
            URL(string: "https://covers.openlibrary.org:444/b/id/1-M.jpg")!,
            URL(string: "https://covers.openlibrary.org/b/id/1-M.jpg#fragment")!
        ]

        for url in rejected {
            await assertStoreError(.disallowedURL) {
                try await store.image(for: url)
            }
        }
        let calls = await transport.callCount
        XCTAssertEqual(calls, 0)
    }

    func testRejectsRedirectEndingOutsideAllowlist() async throws {
        let validImage = try Self.makeImageData(
            width: 40,
            height: 60,
            typeIdentifier: UTType.jpeg.identifier,
            seed: 3
        )
        let transport = StubCoverImageTransport(responses: [
            .http(
                status: 200,
                mimeType: "image/jpeg",
                data: validImage,
                finalURL: URL(string: "https://example.com/redirected.jpg")
            )
        ])
        let store = try CoverImageStore(
            transport: transport,
            cacheDirectory: makeTemporaryDirectory()
        )

        await assertStoreError(.disallowedURL) {
            try await store.image(for: Self.coverURL("redirect"))
        }
        let cached = try await store.cachedImage(for: Self.coverURL("redirect"))
        XCTAssertNil(cached)
    }

    func testRedirectDelegateRejectsDisallowedHostAndPortBeforeFollowingIt() throws {
        let source = Self.coverURL("transport-redirect")
        let rejectedTargets = [
            URL(string: "https://example.com/forbidden-cover.jpg")!,
            URL(string: "https://covers.openlibrary.org:444/b/id/123-L.jpg")!
        ]

        for target in rejectedTargets {
            let redirectResponse = HTTPURLResponse(
                url: source,
                statusCode: 302,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": target.absoluteString]
            )!
            let delegate = CoverImageRedirectDelegate()
            let task = URLSession.shared.dataTask(with: source)
            var followedRequest: URLRequest?

            delegate.urlSession(
                .shared,
                task: task,
                willPerformHTTPRedirection: redirectResponse,
                newRequest: URLRequest(url: target)
            ) { followedRequest = $0 }

            XCTAssertNil(followedRequest)
            XCTAssertTrue(delegate.rejectedRedirect)
        }
    }

    func testRedirectDelegateAllowsAllowlistedHTTPSRedirect() throws {
        let source = Self.coverURL("transport-redirect-source")
        let target = URL(string: "https://covers.openlibrary.org:443/b/id/123-L.jpg")!
        let redirectResponse = HTTPURLResponse(
            url: source,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": target.absoluteString]
        )!
        let delegate = CoverImageRedirectDelegate()
        let task = URLSession.shared.dataTask(with: source)
        var followedRequest: URLRequest?

        delegate.urlSession(
            .shared,
            task: task,
            willPerformHTTPRedirection: redirectResponse,
            newRequest: URLRequest(url: target)
        ) { followedRequest = $0 }

        XCTAssertEqual(followedRequest?.url, target)
        XCTAssertFalse(delegate.rejectedRedirect)
    }

    func testRedirectDelegateAllowsOnlyOpenLibraryArchiveCoverChain() throws {
        let source = Self.coverURL("archive-chain-source")
        let targets = [
            URL(
                string: "https://archive.org/download/m_covers_0010/m_covers_0010_57.zip/0010579085-M.jpg"
            )!,
            URL(
                string: "https://ia800505.us.archive.org/view_archive.php?archive=/25/items/m_covers_0010/m_covers_0010_57.zip&file=0010579085-M.jpg"
            )!,
            URL(
                string: "https://archive.org/download/l_covers_0010/l_covers_0010_57.zip/0010579085-L.jpg"
            )!,
            URL(
                string: "https://ia903209.us.archive.org/view_archive.php?archive=/23/items/s_covers_0010/s_covers_0010_57.zip&file=0010579085-S.jpg"
            )!
        ]
        let delegate = CoverImageRedirectDelegate()
        let task = URLSession.shared.dataTask(with: source)

        for target in targets {
            let response = HTTPURLResponse(
                url: source,
                statusCode: 302,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": target.absoluteString]
            )!
            var followedRequest: URLRequest?

            delegate.urlSession(
                .shared,
                task: task,
                willPerformHTTPRedirection: response,
                newRequest: URLRequest(url: target)
            ) { followedRequest = $0 }

            XCTAssertEqual(followedRequest?.url, target)
            XCTAssertFalse(delegate.rejectedRedirect)
        }
    }

    func testRedirectDelegateRejectsArchiveLookalikesAndUnrelatedPaths() throws {
        let source = Self.coverURL("archive-rejection-source")
        let rejectedTargets = [
            "http://archive.org/download/m_covers_0010/m_covers_0010_57.zip/0010579085-M.jpg",
            "https://user@archive.org/download/m_covers_0010/m_covers_0010_57.zip/0010579085-M.jpg",
            "https://archive.org:444/download/m_covers_0010/m_covers_0010_57.zip/0010579085-M.jpg",
            "https://archive.org/download/unrelated/private.jpg",
            "https://archive.org/download/s_covers_0010/m_covers_0010_57.zip/0010579085-S.jpg",
            "https://archive.org.evil.example/download/m_covers_0010/m_covers_0010_57.zip/0010579085-M.jpg",
            "https://ia800505.us.archive.org/download/private.jpg",
            "https://ia800505.us.archive.org/view_archive.php?archive=/25/items/other.zip&file=0010579085-M.jpg",
            "https://ia800505.us.archive.org/view_archive.php?archive=/25/items/m_covers_0010/m_covers_0010_57.zip&file=../../private.jpg",
            "https://ia800505.us.archive.org/view_archive.php?archive=/25/items/m_covers_0010/m_covers_0010_57.zip&file=0010579085-L.jpg",
            "https://ia800505.us.archive.org/view_archive.php?archive=/25/items/m_covers_0010/m_covers_0010_57.zip&archive=/25/items/m_covers_0010/m_covers_0010_57.zip&file=0010579085-M.jpg",
            "https://ia800505.us.archive.org.evil.example/view_archive.php?archive=/25/items/m_covers_0010/m_covers_0010_57.zip&file=0010579085-M.jpg"
        ].compactMap(URL.init(string:))

        for target in rejectedTargets {
            let response = HTTPURLResponse(
                url: source,
                statusCode: 302,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": target.absoluteString]
            )!
            let delegate = CoverImageRedirectDelegate()
            let task = URLSession.shared.dataTask(with: source)
            var followedRequest: URLRequest?

            delegate.urlSession(
                .shared,
                task: task,
                willPerformHTTPRedirection: response,
                newRequest: URLRequest(url: target)
            ) { followedRequest = $0 }

            XCTAssertNil(followedRequest, target.absoluteString)
            XCTAssertTrue(delegate.rejectedRedirect, target.absoluteString)
        }
    }

    func testArchiveRedirectPayloadUsesOriginalCoverCacheKey() async throws {
        let image = try Self.makeImageData(
            width: 40,
            height: 60,
            typeIdentifier: UTType.jpeg.identifier,
            seed: 31
        )
        let archiveURL = URL(
            string: "https://ia800505.us.archive.org/view_archive.php?archive=/25/items/m_covers_0010/m_covers_0010_57.zip&file=0010579085-M.jpg"
        )!
        let transport = StubCoverImageTransport(responses: [
            .http(
                status: 200,
                mimeType: "image/jpeg",
                data: image,
                finalURL: archiveURL
            )
        ])
        let store = try CoverImageStore(
            transport: transport,
            cacheDirectory: makeTemporaryDirectory()
        )
        let sourceURL = Self.coverURL("archive-cache-key")

        let loaded = try await store.image(for: sourceURL)
        let cached = try await store.cachedImage(for: sourceURL)
        let calls = await transport.callCount

        XCTAssertNotNil(loaded)
        XCTAssertEqual(cached, loaded)
        XCTAssertEqual(calls, 1)
    }

    func testProductionTransportStopsUnknownLengthBodyAtFiveMegabytes() async throws {
        let totalOfferedBytes = 20 * 1_024 * 1_024
        CoverTransportURLProtocol.state.configure(
            .stream(totalBytes: totalOfferedBytes, chunkBytes: 64 * 1_024)
        )
        let session = Self.makeProtocolSession()
        defer { session.invalidateAndCancel() }
        let transport = URLSessionCoverImageTransport(session: session)
        let request = URLRequest(url: Self.coverURL("transport-stream-limit"))

        do {
            _ = try await transport.data(for: request)
            XCTFail("Transport powinien przerwać odpowiedź po przekroczeniu 5 MB.")
        } catch {
            XCTAssertEqual(error as? CoverImageStoreError, .responseTooLarge)
        }

        try await Task.sleep(nanoseconds: 30_000_000)
        let snapshot = CoverTransportURLProtocol.state.snapshot()
        XCTAssertGreaterThan(snapshot.stopCount, 0)
        XCTAssertLessThan(snapshot.deliveredBytes, totalOfferedBytes)
    }

    func testRejectsUnsupportedMIMEAndMislabeledGIFWithoutCaching() async throws {
        let jpeg = try Self.makeImageData(
            width: 20,
            height: 30,
            typeIdentifier: UTType.jpeg.identifier,
            seed: 4
        )
        let gif = try Self.makeImageData(
            width: 20,
            height: 30,
            typeIdentifier: UTType.gif.identifier,
            seed: 5
        )
        let transport = StubCoverImageTransport(responses: [
            .http(status: 200, mimeType: "text/html", data: Data("<html/>".utf8)),
            .http(status: 200, mimeType: "image/svg+xml", data: Data("<svg/>".utf8)),
            .http(status: 200, mimeType: "image/gif", data: gif),
            .http(status: 200, mimeType: "image/jpeg", data: gif),
            .http(status: 200, mimeType: "image/jpeg", data: jpeg)
        ])
        let store = try CoverImageStore(
            transport: transport,
            cacheDirectory: makeTemporaryDirectory()
        )
        let url = Self.coverURL("mime")

        await assertStoreError(.unsupportedContentType("text/html")) {
            try await store.image(for: url)
        }
        await assertStoreError(.unsupportedContentType("image/svg+xml")) {
            try await store.image(for: url)
        }
        await assertStoreError(.unsupportedContentType("image/gif")) {
            try await store.image(for: url)
        }
        await assertStoreError(.invalidImage) {
            try await store.image(for: url)
        }

        let finalPayload = try await store.image(for: url)
        let calls = await transport.callCount
        XCTAssertNotNil(finalPayload)
        XCTAssertEqual(calls, 5)
    }

    func testAcceptsPNGAndWebP() async throws {
        let png = try Self.makeImageData(
            width: 30,
            height: 45,
            typeIdentifier: UTType.png.identifier,
            seed: 6
        )
        let pngTransport = StubCoverImageTransport(responses: [
            .http(status: 200, mimeType: "image/png", data: png)
        ])
        let pngStore = try CoverImageStore(
            transport: pngTransport,
            cacheDirectory: makeTemporaryDirectory()
        )
        let pngResult = try await pngStore.image(for: Self.coverURL("png"))
        XCTAssertEqual(pngResult?.mimeType, "image/jpeg")

        // A valid 1x1 lossy WebP. ImageIO on iOS decodes WebP but does not
        // expose a WebP image destination, so the fixture is intentionally raw.
        let webP = try XCTUnwrap(Data(
            base64Encoded: "UklGRiIAAABXRUJQVlA4IBYAAAAwAQCdASoBAAEADsD+JaQAA3AAAAAA"
        ))
        let webPTransport = StubCoverImageTransport(responses: [
            .http(status: 200, mimeType: "image/webp", data: webP)
        ])
        let webPStore = try CoverImageStore(
            transport: webPTransport,
            cacheDirectory: makeTemporaryDirectory()
        )
        let webPResult = try await webPStore.image(for: Self.coverURL("webp"))
        XCTAssertEqual(webPResult?.mimeType, "image/jpeg")
    }

    func testRejectsPayloadOverFiveMegabytesAndPixelBomb() async throws {
        let oversizedTransport = StubCoverImageTransport(responses: [
            .http(
                status: 200,
                mimeType: "image/jpeg",
                data: Data(count: CoverImageStore.Configuration.maximumAllowedInputBytes + 1)
            )
        ])
        let oversizedStore = try CoverImageStore(
            transport: oversizedTransport,
            cacheDirectory: makeTemporaryDirectory()
        )
        await assertStoreError(.responseTooLarge) {
            try await oversizedStore.image(for: Self.coverURL("oversized"))
        }

        let tinyImage = try Self.makeImageData(
            width: 2,
            height: 2,
            typeIdentifier: UTType.jpeg.identifier,
            seed: 8
        )
        let pixelTransport = StubCoverImageTransport(responses: [
            .http(status: 200, mimeType: "image/jpeg", data: tinyImage)
        ])
        let pixelStore = try CoverImageStore(
            transport: pixelTransport,
            cacheDirectory: makeTemporaryDirectory(),
            configuration: .init(maximumSourcePixelCount: 3)
        )
        await assertStoreError(.pixelCountExceeded) {
            try await pixelStore.image(for: Self.coverURL("pixel-bomb"))
        }
    }

    func test404NegativeCachePersistsForTwentyFourHoursThenExpires() async throws {
        let clock = LockedTestClock(Date(timeIntervalSince1970: 1_000_000))
        let directory = makeTemporaryDirectory()
        let firstTransport = StubCoverImageTransport(responses: [
            .http(status: 404, mimeType: nil, data: Data())
        ])
        let firstStore = try CoverImageStore(
            transport: firstTransport,
            cacheDirectory: directory,
            clock: clock.coverClock
        )
        let url = Self.coverURL("negative")

        let firstMiss = try await firstStore.image(for: url)
        let cachedMiss = try await firstStore.image(for: url)
        let firstCalls = await firstTransport.callCount
        XCTAssertNil(firstMiss)
        XCTAssertNil(cachedMiss)
        XCTAssertEqual(firstCalls, 1)

        let validImage = try Self.makeImageData(
            width: 40,
            height: 60,
            typeIdentifier: UTType.jpeg.identifier,
            seed: 9
        )
        let secondTransport = StubCoverImageTransport(responses: [
            .http(status: 200, mimeType: "image/jpeg", data: validImage)
        ])
        let restartedStore = try CoverImageStore(
            transport: secondTransport,
            cacheDirectory: directory,
            clock: clock.coverClock
        )

        clock.advance(by: (24 * 60 * 60) - 1)
        let unexpiredMiss = try await restartedStore.image(for: url)
        let callsBeforeExpiry = await secondTransport.callCount
        XCTAssertNil(unexpiredMiss)
        XCTAssertEqual(callsBeforeExpiry, 0)

        clock.advance(by: 2)
        let refreshed = try await restartedStore.image(for: url)
        let callsAfterExpiry = await secondTransport.callCount
        XCTAssertNotNil(refreshed)
        XCTAssertEqual(callsAfterExpiry, 1)
    }

    func testNon404FailureDoesNotCreateNegativeCache() async throws {
        let transport = StubCoverImageTransport(responses: [
            .http(status: 503, mimeType: "text/plain", data: Data()),
            .http(status: 503, mimeType: "text/plain", data: Data())
        ])
        let store = try CoverImageStore(
            transport: transport,
            cacheDirectory: makeTemporaryDirectory()
        )
        let url = Self.coverURL("server-error")

        for _ in 0..<2 {
            await assertStoreError(.httpStatus(503)) {
                try await store.image(for: url)
            }
        }
        let calls = await transport.callCount
        XCTAssertEqual(calls, 2)
    }

    func testTransportCancellationDoesNotCreateNegativeCache() async throws {
        let validImage = try Self.makeImageData(
            width: 40,
            height: 60,
            typeIdentifier: UTType.jpeg.identifier,
            seed: 10
        )
        let transport = StubCoverImageTransport(responses: [
            .cancellation,
            .http(status: 200, mimeType: "image/jpeg", data: validImage)
        ])
        let store = try CoverImageStore(
            transport: transport,
            cacheDirectory: makeTemporaryDirectory()
        )
        let url = Self.coverURL("cancelled")

        do {
            _ = try await store.image(for: url)
            XCTFail("Anulowany transport powinien propagować CancellationError.")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Nieoczekiwany błąd: \(error)")
        }

        let retried = try await store.image(for: url)
        let calls = await transport.callCount
        XCTAssertNotNil(retried)
        XCTAssertEqual(calls, 2)
    }

    func testTwentyConcurrentReadersShareOneTransportRequest() async throws {
        let image = try Self.makeImageData(
            width: 80,
            height: 120,
            typeIdentifier: UTType.jpeg.identifier,
            seed: 11
        )
        let transport = StubCoverImageTransport(responses: [
            .http(
                status: 200,
                mimeType: "image/jpeg",
                data: image,
                delayNanoseconds: 100_000_000
            )
        ])
        let store = try CoverImageStore(
            transport: transport,
            cacheDirectory: makeTemporaryDirectory()
        )
        let url = Self.coverURL("coalesced")

        let results = try await withThrowingTaskGroup(of: CoverImagePayload?.self) { group in
            for _ in 0..<20 {
                group.addTask { try await store.image(for: url) }
            }
            var values: [CoverImagePayload?] = []
            for try await value in group {
                values.append(value)
            }
            return values
        }

        XCTAssertEqual(results.count, 20)
        XCTAssertTrue(results.allSatisfy { $0 != nil })
        let calls = await transport.callCount
        XCTAssertEqual(calls, 1)
    }

    func testExplicitHTTPSDefaultPortSharesOneCacheKeyAndFlight() async throws {
        let image = try Self.makeImageData(
            width: 80,
            height: 120,
            typeIdentifier: UTType.jpeg.identifier,
            seed: 11
        )
        let transport = StubCoverImageTransport(responses: [
            .http(
                status: 200,
                mimeType: "image/jpeg",
                data: image,
                delayNanoseconds: 100_000_000
            )
        ])
        let store = try CoverImageStore(
            transport: transport,
            cacheDirectory: makeTemporaryDirectory()
        )
        let defaultPortURL = Self.coverURL("default-port")
        let explicitPortURL = URL(
            string: "https://covers.openlibrary.org:443/b/id/default-port-M.jpg?default=false"
        )!

        async let defaultPortPayload = store.image(for: defaultPortURL)
        async let explicitPortPayload = store.image(for: explicitPortURL)
        let payloads = try await (defaultPortPayload, explicitPortPayload)

        XCTAssertNotNil(payloads.0)
        XCTAssertEqual(payloads.0, payloads.1)
        let calls = await transport.callCount
        XCTAssertEqual(calls, 1)
    }

    func testCancellingOneWaiterKeepsSharedRequestForOtherWaiter() async throws {
        let image = try Self.makeImageData(
            width: 80,
            height: 120,
            typeIdentifier: UTType.jpeg.identifier,
            seed: 12
        )
        let transport = StubCoverImageTransport(responses: [
            .http(
                status: 200,
                mimeType: "image/jpeg",
                data: image,
                delayNanoseconds: 150_000_000
            )
        ])
        let store = try CoverImageStore(
            transport: transport,
            cacheDirectory: makeTemporaryDirectory()
        )
        let url = Self.coverURL("one-waiter-cancelled")
        let cancelledWaiter = Task { try await store.image(for: url) }
        let survivingWaiter = Task { try await store.image(for: url) }

        try await Task.sleep(nanoseconds: 20_000_000)
        cancelledWaiter.cancel()

        do {
            _ = try await cancelledWaiter.value
            XCTFail("Anulowany waiter powinien otrzymać CancellationError.")
        } catch is CancellationError {
            // Expected.
        }
        let survivingPayload = try await survivingWaiter.value
        let calls = await transport.callCount
        XCTAssertNotNil(survivingPayload)
        XCTAssertEqual(calls, 1)
    }

    func testCancellingLastWaiterCancelsFlightAndRetryStartsNewRequest() async throws {
        let image = try Self.makeImageData(
            width: 80,
            height: 120,
            typeIdentifier: UTType.jpeg.identifier,
            seed: 13
        )
        let transport = StubCoverImageTransport(responses: [
            .http(
                status: 200,
                mimeType: "image/jpeg",
                data: image,
                delayNanoseconds: 5_000_000_000
            ),
            .http(status: 200, mimeType: "image/jpeg", data: image)
        ])
        let store = try CoverImageStore(
            transport: transport,
            cacheDirectory: makeTemporaryDirectory()
        )
        let url = Self.coverURL("last-waiter-cancelled")
        let first = Task { try await store.image(for: url) }

        try await Task.sleep(nanoseconds: 20_000_000)
        first.cancel()
        do {
            _ = try await first.value
            XCTFail("Anulowany ostatni waiter powinien otrzymać CancellationError.")
        } catch is CancellationError {
            // Expected.
        }

        let retried = try await store.image(for: url)
        let calls = await transport.callCount
        XCTAssertNotNil(retried)
        XCTAssertEqual(calls, 2)
    }

    func testDiskLRUEvictsLeastRecentlyUsedEntryDeterministically() async throws {
        let inputs = try (20...22).map { seed in
            try Self.makeImageData(
                width: 96,
                height: 128,
                typeIdentifier: UTType.jpeg.identifier,
                seed: seed
            )
        }
        let urls = [Self.coverURL("lru-a"), Self.coverURL("lru-b"), Self.coverURL("lru-c")]

        let probeTransport = StubCoverImageTransport(responses: inputs.map {
            .http(status: 200, mimeType: "image/jpeg", data: $0)
        })
        let probeStore = try CoverImageStore(
            transport: probeTransport,
            cacheDirectory: makeTemporaryDirectory()
        )
        var sanitizedSizes: [Int] = []
        for (index, url) in urls.enumerated() {
            let probePayload = try await probeStore.image(for: url)
            sanitizedSizes.append(try XCTUnwrap(probePayload).data.count)
            let calls = await probeTransport.callCount
            XCTAssertEqual(calls, index + 1)
        }
        let twoEntryBudget = max(
            sanitizedSizes[0] + sanitizedSizes[1],
            sanitizedSizes[0] + sanitizedSizes[2]
        )

        let transport = StubCoverImageTransport(responses: inputs.map {
            .http(status: 200, mimeType: "image/jpeg", data: $0)
        })
        let store = try CoverImageStore(
            transport: transport,
            cacheDirectory: makeTemporaryDirectory(),
            configuration: .init(
                maximumMemoryBytes: 0,
                maximumDiskBytes: twoEntryBudget
            )
        )

        _ = try await store.image(for: urls[0])
        _ = try await store.image(for: urls[1])
        let touchedA = try await store.cachedImage(for: urls[0])
        XCTAssertNotNil(touchedA) // Touch A; B is now LRU.
        _ = try await store.image(for: urls[2])

        let cachedA = try await store.cachedImage(for: urls[0])
        let cachedB = try await store.cachedImage(for: urls[1])
        let cachedC = try await store.cachedImage(for: urls[2])
        XCTAssertNotNil(cachedA)
        XCTAssertNil(cachedB)
        XCTAssertNotNil(cachedC)
    }

    func testCorruptDiskEntryIsRemovedAndCanBeRefetched() async throws {
        let image = try Self.makeImageData(
            width: 50,
            height: 75,
            typeIdentifier: UTType.jpeg.identifier,
            seed: 30
        )
        let directory = makeTemporaryDirectory()
        let firstTransport = StubCoverImageTransport(responses: [
            .http(status: 200, mimeType: "image/jpeg", data: image)
        ])
        let url = Self.coverURL("corrupt")
        let firstStore = try CoverImageStore(
            transport: firstTransport,
            cacheDirectory: directory,
            configuration: .init(maximumMemoryBytes: 0)
        )
        _ = try await firstStore.image(for: url)

        let imageFile = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ).first(where: { $0.pathExtension == "jpg" })
        )
        try Data("corrupt".utf8).write(to: imageFile, options: .atomic)

        let secondTransport = StubCoverImageTransport(responses: [
            .http(status: 200, mimeType: "image/jpeg", data: image)
        ])
        let restartedStore = try CoverImageStore(
            transport: secondTransport,
            cacheDirectory: directory,
            configuration: .init(maximumMemoryBytes: 0)
        )

        let corruptCached = try await restartedStore.cachedImage(for: url)
        let refetched = try await restartedStore.image(for: url)
        let calls = await secondTransport.callCount
        XCTAssertNil(corruptCached)
        XCTAssertNotNil(refetched)
        XCTAssertEqual(calls, 1)
    }

    func testOversizedDiskEntryIsRemovedBeforeItCanBeReturned() async throws {
        let image = try Self.makeImageData(
            width: 50,
            height: 75,
            typeIdentifier: UTType.jpeg.identifier,
            seed: 31
        )
        let directory = makeTemporaryDirectory()
        let transport = StubCoverImageTransport(responses: [
            .http(status: 200, mimeType: "image/jpeg", data: image)
        ])
        let url = Self.coverURL("oversized-disk-entry")
        let store = try CoverImageStore(
            transport: transport,
            cacheDirectory: directory,
            configuration: .init(maximumMemoryBytes: 0)
        )
        _ = try await store.image(for: url)
        let imageFile = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ).first(where: { $0.pathExtension == "jpg" })
        )
        try Data(
            repeating: 0xA5,
            count: CoverImageStore.Configuration.maximumAllowedInputBytes + 1
        ).write(to: imageFile, options: .atomic)

        let cached = try await store.cachedImage(for: url)
        XCTAssertNil(cached)
        XCTAssertFalse(FileManager.default.fileExists(atPath: imageFile.path))
        let callsAfterDiskMiss = await transport.callCount
        XCTAssertEqual(callsAfterDiskMiss, 1)

        let refetched = try await store.image(for: url)
        XCTAssertNotNil(refetched)
        let callsAfterRefetch = await transport.callCount
        XCTAssertEqual(callsAfterRefetch, 2)
    }

    func testTamperedDiskJPEGOutsideOutputDimensionsIsRemoved() async throws {
        let image = try Self.makeImageData(
            width: 50,
            height: 75,
            typeIdentifier: UTType.jpeg.identifier,
            seed: 32
        )
        let tamperedImage = try Self.makeImageData(
            width: 101,
            height: 60,
            typeIdentifier: UTType.jpeg.identifier,
            seed: 33
        )
        let directory = makeTemporaryDirectory()
        let transport = StubCoverImageTransport(responses: [
            .http(status: 200, mimeType: "image/jpeg", data: image)
        ])
        let url = Self.coverURL("oversized-dimensions")
        let store = try CoverImageStore(
            transport: transport,
            cacheDirectory: directory,
            configuration: .init(
                maximumOutputDimension: 100,
                maximumMemoryBytes: 0
            )
        )
        _ = try await store.image(for: url)
        let imageFile = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ).first(where: { $0.pathExtension == "jpg" })
        )
        try tamperedImage.write(to: imageFile, options: .atomic)

        let cached = try await store.cachedImage(for: url)
        XCTAssertNil(cached)
        XCTAssertFalse(FileManager.default.fileExists(atPath: imageFile.path))

        let refetched = try await store.image(for: url)
        XCTAssertNotNil(refetched)
        let calls = await transport.callCount
        XCTAssertEqual(calls, 2)
    }
}

private extension CoverImageStoreTests {
    func makeTemporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoverImageStoreTests-\(UUID().uuidString)", isDirectory: true)
        temporaryDirectories.append(directory)
        return directory
    }

    func assertStoreError<T>(
        _ expected: CoverImageStoreError,
        operation: () async throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await operation()
            XCTFail("Oczekiwano błędu \(expected).", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? CoverImageStoreError, expected, file: file, line: line)
        }
    }

    static func coverURL(_ suffix: String) -> URL {
        URL(string: "https://covers.openlibrary.org/b/id/\(suffix)-M.jpg?default=false")!
    }

    static func makeProtocolSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CoverTransportURLProtocol.self]
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }

    static func makeImageData(
        width: Int,
        height: Int,
        typeIdentifier: String,
        seed: Int,
        includesEXIF: Bool = false
    ) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ImageFixtureError.cannotCreateContext
        }

        let red = CGFloat((seed * 47) % 255) / 255
        let green = CGFloat((seed * 83) % 255) / 255
        let blue = CGFloat((seed * 131) % 255) / 255
        context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 1 - red, green: 1 - green, blue: 1 - blue, alpha: 1))
        context.fill(CGRect(x: width / 5, y: height / 4, width: width / 2, height: height / 3))

        guard let image = context.makeImage() else {
            throw ImageFixtureError.cannotCreateImage
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            typeIdentifier as CFString,
            1,
            nil
        ) else {
            throw ImageFixtureError.unsupportedDestination(typeIdentifier)
        }

        var properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.9
        ]
        if includesEXIF {
            properties[kCGImagePropertyExifDictionary] = [
                kCGImagePropertyExifUserComment: "private fixture metadata"
            ]
            properties[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: 52.2297,
                kCGImagePropertyGPSLongitude: 21.0122
            ]
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ImageFixtureError.cannotFinalize
        }
        return output as Data
    }
}

private enum ImageFixtureError: Error {
    case cannotCreateContext
    case cannotCreateImage
    case unsupportedDestination(String)
    case cannotFinalize
}

private enum StubCoverResponse: Sendable {
    case http(
        status: Int,
        mimeType: String?,
        data: Data,
        finalURL: URL? = nil,
        declaredLength: Int? = nil,
        delayNanoseconds: UInt64 = 0
    )
    case cancellation
}

private actor StubCoverImageTransport: CoverImageTransport {
    private let responses: [StubCoverResponse]
    private(set) var callCount = 0

    init(responses: [StubCoverResponse]) {
        precondition(!responses.isEmpty)
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let index = min(callCount, responses.count - 1)
        let response = responses[index]
        callCount += 1

        switch response {
        case .cancellation:
            throw CancellationError()

        case .http(
            let status,
            let mimeType,
            let data,
            let finalURL,
            let declaredLength,
            let delayNanoseconds
        ):
            if delayNanoseconds > 0 {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            }
            var headers: [String: String] = [
                "Content-Length": String(declaredLength ?? data.count)
            ]
            if let mimeType {
                headers["Content-Type"] = mimeType
            }
            let httpResponse = HTTPURLResponse(
                url: finalURL ?? request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            return (data, httpResponse)
        }
    }
}

private final class LockedTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    var coverClock: CoverImageClock {
        CoverImageClock { [self] in currentDate() }
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        value = value.addingTimeInterval(interval)
        lock.unlock()
    }

    private func currentDate() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class CoverTransportURLProtocol: URLProtocol, @unchecked Sendable {
    static let state = CoverTransportURLProtocolState()

    private let stopLock = NSLock()
    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        switch Self.state.currentScenario {
        case .stream(let totalBytes, let chunkBytes):
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "image/jpeg"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                let chunk = Data(repeating: 0xA5, count: chunkBytes)
                var remaining = totalBytes
                while remaining > 0, !self.isStopped {
                    let count = min(remaining, chunkBytes)
                    let payload = count == chunkBytes ? chunk : Data(chunk.prefix(count))
                    self.client?.urlProtocol(self, didLoad: payload)
                    Self.state.recordDeliveredBytes(count)
                    remaining -= count
                    Thread.sleep(forTimeInterval: 0.005)
                }
                if !self.isStopped {
                    self.client?.urlProtocolDidFinishLoading(self)
                }
            }
        }
    }

    override func stopLoading() {
        stopLock.lock()
        let wasAlreadyStopped = stopped
        stopped = true
        stopLock.unlock()
        if !wasAlreadyStopped {
            Self.state.recordStop()
        }
    }

    private var isStopped: Bool {
        stopLock.lock()
        defer { stopLock.unlock() }
        return stopped
    }
}

private final class CoverTransportURLProtocolState: @unchecked Sendable {
    enum Scenario {
        case stream(totalBytes: Int, chunkBytes: Int)
    }

    struct Snapshot {
        let deliveredBytes: Int
        let stopCount: Int
    }

    private let lock = NSLock()
    private var scenario: Scenario = .stream(totalBytes: 0, chunkBytes: 1)
    private var deliveredBytes = 0
    private var stopCount = 0

    var currentScenario: Scenario {
        lock.lock()
        defer { lock.unlock() }
        return scenario
    }

    func configure(_ scenario: Scenario) {
        lock.lock()
        self.scenario = scenario
        deliveredBytes = 0
        stopCount = 0
        lock.unlock()
    }

    func recordDeliveredBytes(_ count: Int) {
        lock.lock()
        deliveredBytes += count
        lock.unlock()
    }

    func recordStop() {
        lock.lock()
        stopCount += 1
        lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            deliveredBytes: deliveredBytes,
            stopCount: stopCount
        )
    }
}

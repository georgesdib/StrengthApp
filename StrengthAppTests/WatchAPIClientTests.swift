import XCTest
@testable import StrengthApp
import StrengthCore

@MainActor
final class WatchAPIClientTests: XCTestCase {
    func testMintWatchSendsPhoneBearerAndDecodesTheWatchDevice() async throws {
        let transport = StubTransport { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/ios/v1/devices/watch")
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer phone-token"
            )
            let body = try XCTUnwrap(request.httpBody)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
            XCTAssertEqual(json["label"], "Apple Watch")
            return (201, Data("""
            {
              "device": {
                "device_id": "watch-1",
                "label": "Apple Watch",
                "kind": "watch",
                "parent_device_id": "phone-1",
                "credential_epoch": 2
              },
              "token": "watch-token",
              "created_at": "2026-11-10T20:00:00+00:00",
              "replaced_device_id": "watch-0"
            }
            """.utf8))
        }
        let client = IOSAPIClient(transport: transport)
        let response = try await client.mintWatch(
            session: IOSSession(
                baseURL: URL(string: "http://home.local:8000")!,
                token: "phone-token",
                deviceID: "phone-1"
            )
        )
        XCTAssertEqual(response.device.deviceId, "watch-1")
        XCTAssertEqual(response.device.credentialEpoch, 2)
        XCTAssertEqual(response.token, "watch-token")
        XCTAssertEqual(response.replacedDeviceId, "watch-0")
    }

    func testDevicesDecodesTheWatchList() async throws {
        let transport = StubTransport { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/ios/v1/devices")
            return (200, Data("""
            {
              "devices": [
                {
                  "device_id": "watch-1",
                  "label": "Apple Watch",
                  "kind": "watch",
                  "parent_device_id": "phone-1",
                  "credential_epoch": 3,
                  "created_at": "2026-11-10T20:00:00+00:00",
                  "last_seen_at": null,
                  "revoked_at": null
                }
              ]
            }
            """.utf8))
        }
        let client = IOSAPIClient(transport: transport)
        let response = try await client.devices(
            session: IOSSession(
                baseURL: URL(string: "http://home.local:8000")!,
                token: "phone-token",
                deviceID: "phone-1"
            )
        )
        XCTAssertEqual(response.devices.count, 1)
        XCTAssertEqual(response.devices[0].kind, "watch")
        XCTAssertEqual(response.devices[0].credentialEpoch, 3)
        XCTAssertNil(response.devices[0].revokedAt)
    }

    func testRevokeDeviceUsesDeleteAndDecodesCascadeIDs() async throws {
        let transport = StubTransport { request in
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertEqual(request.url?.path, "/api/ios/v1/devices/watch-1")
            return (200, Data("""
            {
              "device_id": "watch-1",
              "revoked_at": "2026-11-10T20:01:00+00:00",
              "already_revoked": false,
              "revoked_watch_ids": ["watch-1"]
            }
            """.utf8))
        }
        let client = IOSAPIClient(transport: transport)
        let response = try await client.revokeDevice(
            deviceId: "watch-1",
            session: IOSSession(
                baseURL: URL(string: "http://home.local:8000")!,
                token: "phone-token",
                deviceID: "phone-1"
            )
        )
        XCTAssertEqual(response.deviceId, "watch-1")
        XCTAssertEqual(response.revokedWatchIds, ["watch-1"])
        XCTAssertFalse(response.alreadyRevoked)
    }
}

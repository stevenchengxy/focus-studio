import FocusStudioAutomation
import Foundation

enum NativeSubscriptionRegression {
    static func run() throws {
        let reservation = ExportReservation(id: UUID().uuidString)
        // Accept the actual API response, including fields not needed here.
        let valid = try JSONSerialization.data(withJSONObject: [
            "exportId": reservation.id, "status": "committed", "mode": "trial", "expiresAt": 1_900_000_000
        ])
        try NativeSubscriptionClient.validateCommitReceipt(valid, reservation: reservation)

        let invalidReceipts: [Data] = [
            Data(), Data("<html>OK</html>".utf8), Data("{}".utf8),
            try JSONSerialization.data(withJSONObject: ["exportId": UUID().uuidString, "status": "committed"]),
            try JSONSerialization.data(withJSONObject: ["exportId": reservation.id, "status": "reserved"]),
            try JSONSerialization.data(withJSONObject: ["exportId": reservation.id, "status": "released"]),
            try JSONSerialization.data(withJSONObject: ["exportId": reservation.id, "status": "expired"]),
            try JSONSerialization.data(withJSONObject: ["exportId": reservation.id, "status": true]),
        ]
        for data in invalidReceipts {
            do {
                try NativeSubscriptionClient.validateCommitReceipt(data, reservation: reservation)
                preconditionFailure("An unconfirmed commit receipt must not authorize output publication")
            } catch let error as SubscriptionServiceError {
                precondition(error.code == "invalid_response")
                precondition(!error.commitOutcomeIsKnown,
                    "Invalid receipts must preserve the completed video and recovery journal, not release or discard them")
            }
        }
        print("NativeSubscriptionRegression: PASS (matching committed receipt; malformed, unrelated and uncommitted receipts remain recoverable)")
    }
}

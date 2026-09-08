import Foundation
import USBGateKit

/// A drive that could be authorised: attached now, or refused earlier.
///
/// `status` lists both and points at `allow`, so `allow` has to offer both.
/// Offering only the refused queue is why "nothing has been refused" could appear
/// while three unauthorised drives were plugged in.
struct Candidate {
    let device: Device
    let name: String
    let note: String
}

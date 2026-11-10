import ABSCore
import ABSPlayback
import AVFoundation
import Testing

@Suite struct NetworkAccessURLAssetTests {
    @Test(arguments: [
        (CellularPolicy.always, false, [true, true, true]),
        (.always, true, [true, true, true]),
        (.ask, false, [true, true, true]),
        (.ask, true, [true, true, true]),
        (.never, false, [false, true, false]),
        (.never, true, [false, false, false]),
    ])
    func optionsMirrorTheFlags(policy: CellularPolicy, treatsExpensiveAsCellular: Bool, expected: [Bool]) {
        let access = NetworkAccess(policy: policy, treatsExpensiveAsCellular: treatsExpensiveAsCellular)
        #expect(
            access.urlAssetOptions == [
                AVURLAssetAllowsCellularAccessKey: expected[0],
                AVURLAssetAllowsExpensiveNetworkAccessKey: expected[1],
                AVURLAssetAllowsConstrainedNetworkAccessKey: expected[2],
            ])
    }

}

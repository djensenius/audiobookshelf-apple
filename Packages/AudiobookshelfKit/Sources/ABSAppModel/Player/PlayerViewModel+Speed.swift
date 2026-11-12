extension PlayerViewModel {
    /// Whether the speed stepper can move the rate up or down a step (D1).
    public func canStepRate(up: Bool) -> Bool {
        PlaybackSpeed.stepped(rate, up: up) != nil
    }

    /// Moves the rate one step up or down and saves it, as each stepper tap applies at once (D3).
    /// Does nothing at the end of ``PlaybackSpeed/range``.
    public func stepRate(up: Bool) {
        guard let next = PlaybackSpeed.stepped(rate, up: up) else { return }
        setRate(next)
    }
}

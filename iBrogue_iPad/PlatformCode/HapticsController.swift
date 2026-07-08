//
//  HapticsController.swift
//  Brogue
//
//  Owns the tactile-feedback generators and the on/off setting. Extracted from
//  BrogueViewController.swift so the (pure-output) haptics concern lives in one place.
//  The view controller keeps thin @objc forwarders that the C engine bridges call by
//  selector; those delegate here. iPhone-only (iPad has no Taptic Engine) — every
//  engine-driven entry point guards on that and on the enabled setting, and hops to
//  the main thread since the engine calls in on its own background thread.
//

import UIKit

final class HapticsController {

    /// All hand-tunable haptic parameters in one place. Adjust feel here; nothing
    /// else hard-codes a style, intensity, or severity level. The `severity*`
    /// values must stay in sync with the engine's Combat.c damage hook.
    private enum Config {
        // Generator styles.
        static let buttonStyle: UIImpactFeedbackGenerator.FeedbackStyle = .soft
        static let lightDamageStyle: UIImpactFeedbackGenerator.FeedbackStyle = .medium
        static let strongDamageStyle: UIImpactFeedbackGenerator.FeedbackStyle = .heavy

        // Impact intensities (0...1). NOTE: iOS effectively drops impacts below
        // ~0.4 (imperceptible / not fired), so keep these at 0.4 or above.
        static let buttonIntensity: CGFloat = 0.6          // on-screen button tap / option feedback
        static let ordinaryDamageIntensity: CGFloat = 0.6  // severity 0: routine hit
        static let lowHealthDamageIntensity: CGFloat = 0.8 // severity 1: hit while under 40% HP
        // Death (severity 2) uses a notification buzz instead of an impact:
        static let deathNotification: UINotificationFeedbackGenerator.FeedbackType = .error

        // Damage severity levels passed up from the engine (see Combat.c).
        static let severityLowHealth = 1
        static let severityFatal = 2

        // Noise-detection feedback (Brogue SE noise system, see Monsters.c). Sharp/crisp
        // so it reads as an "alert," distinct from the softer damage thuds.
        static let detectionStyle: UIImpactFeedbackGenerator.FeedbackStyle = .rigid
        static let detectionIntensity: CGFloat = 0.7
        static let detectionDoubleGap: TimeInterval = 0.09  // gap between the two "now hunting" taps
        static let detectionStageHunting = 1                // stage >= this -> double tap

        // Environmental-noise feedback (Brogue SE noise system, see Time.c / Architect.c): a noisy
        // WORLD EVENT near the player, distinct from the detection "alert." kind 0 = a trap's soft
        // click underfoot (gentle, single light tick); kind 1 = reward-room machinery grinding shut
        // (pronounced, heavy thud + a short second tap to evoke the grind).
        static let trapClickStyle: UIImpactFeedbackGenerator.FeedbackStyle = .light
        static let trapClickIntensity: CGFloat = 0.5        // gentle (but >= the ~0.4 perceptible floor)
        static let altarGrindStyle: UIImpactFeedbackGenerator.FeedbackStyle = .heavy
        static let altarGrindIntensity: CGFloat = 1.0       // the heaviest noise haptic in the game
        static let altarGrindDoubleGap: TimeInterval = 0.07 // gap before the grind's second tap
        static let envNoiseKindAltar = 1                    // kind >= this -> pronounced (double-tap grind)
    }

    private static let enabledDefaultsKey = "hapticsEnabled"

    /// Tactile feedback when an action button is tapped.
    private let actionButtonHaptics = UIImpactFeedbackGenerator(style: Config.buttonStyle)

    /// Generators for the take-damage feedback: a soft tick for ordinary hits and
    /// a heavy one for low-health hits, plus a notification generator for death.
    private let lightDamageHaptics = UIImpactFeedbackGenerator(style: Config.lightDamageStyle)
    private let strongDamageHaptics = UIImpactFeedbackGenerator(style: Config.strongDamageStyle)
    private let deathHaptics = UINotificationFeedbackGenerator()

    /// Generator for noise-detection feedback (sharp taps when something hears you).
    private let detectionHaptics = UIImpactFeedbackGenerator(style: Config.detectionStyle)

    /// Generators for environmental-noise feedback: a gentle tick for a trap click and a
    /// heavy thud for an altar grinding shut.
    private let trapClickHaptics = UIImpactFeedbackGenerator(style: Config.trapClickStyle)
    private let altarGrindHaptics = UIImpactFeedbackGenerator(style: Config.altarGrindStyle)

    /// Whether tactile feedback is on. User-toggleable from the title options;
    /// persisted and shared across Classic and CE. Defaults on.
    private(set) var isEnabled: Bool = {
        // Absent key → default on; honor an explicit stored value otherwise.
        UserDefaults.standard.object(forKey: HapticsController.enabledDefaultsKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: HapticsController.enabledDefaultsKey)
    }()

    /// A phone has a Taptic Engine; iPad does not.
    private var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }

    /// Flips the setting and persists it. When turning on, warms the button generator
    /// and gives a confirming tap so the change is felt immediately.
    func setEnabled(_ on: Bool) {
        isEnabled = on
        UserDefaults.standard.set(on, forKey: HapticsController.enabledDefaultsKey)
        if on {
            actionButtonHaptics.prepare()
            actionButtonHaptics.impactOccurred(intensity: Config.buttonIntensity)
        }
    }

    /// Fires the action-button haptic, unless the user has disabled haptics.
    func fireButton() {
        guard isEnabled else { return }
        actionButtonHaptics.impactOccurred(intensity: Config.buttonIntensity)
    }

    /// Warms the button and take-damage generators so the first tap / hit isn't dropped
    /// by a cold Taptic Engine. Called when gameplay controls appear.
    func warmUp() {
        guard isEnabled else { return }
        actionButtonHaptics.prepare()
        lightDamageHaptics.prepare()
        strongDamageHaptics.prepare()
        deathHaptics.prepare()
        detectionHaptics.prepare()
        trapClickHaptics.prepare()
        altarGrindHaptics.prepare()
    }

    /// Tactile feedback when the player takes damage, scaled by severity (computed
    /// by the engine): 0 = ordinary hit (very light), 1 = hit while under 40%
    /// health, the threshold of the engine's low-health flash (stronger), 2 =
    /// killing blow (very strong). Respects the haptics setting and is iPhone-only
    /// (iPad has no haptic engine). Called from both engine bridges on the engine's
    /// background thread, so it hops to main.
    func playDamage(severity: Int) {
        guard isEnabled, isPhone else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if severity >= Config.severityFatal {            // death — very strong, distinct buzz
                self.deathHaptics.notificationOccurred(Config.deathNotification)
                self.deathHaptics.prepare()
            } else if severity >= Config.severityLowHealth {  // low health (<40%) — stronger thud
                self.strongDamageHaptics.impactOccurred(intensity: Config.lowHealthDamageIntensity)
                self.strongDamageHaptics.prepare()             // keep warm for the next hit
            } else {                                           // ordinary hit — very light tick
                self.lightDamageHaptics.impactOccurred(intensity: Config.ordinaryDamageIntensity)
                self.lightDamageHaptics.prepare()
            }
        }
    }

    /// Tactile feedback when an unseen creature reacts to the player's noise (Brogue
    /// SE noise system): stage 0 = something just began investigating you (one short,
    /// sharp tap); stage 1 = an investigator locked onto you and is now hunting (two
    /// quick taps). Respects the haptics setting and is iPhone-only. Called from the
    /// SE bridge on the engine's background thread, so it hops to main.
    func playNoiseDetection(stage: Int) {
        guard isEnabled, isPhone else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.detectionHaptics.impactOccurred(intensity: Config.detectionIntensity)
            self.detectionHaptics.prepare()
            if stage >= Config.detectionStageHunting {   // it found you — a second quick tap
                DispatchQueue.main.asyncAfter(deadline: .now() + Config.detectionDoubleGap) { [weak self] in
                    guard let self = self else { return }
                    self.detectionHaptics.impactOccurred(intensity: Config.detectionIntensity)
                    self.detectionHaptics.prepare()
                }
            }
        }
    }

    /// Tactile feedback when a noisy world event happens near the player (Brogue SE noise
    /// system): kind 0 = a trap's soft click underfoot (one gentle light tick); kind 1 = an
    /// altar / reward-room machinery grinding shut (a heavy thud followed by a short second
    /// tap, evoking the grind). Respects the haptics setting and is iPhone-only. Called from
    /// the SE bridge on the engine's background thread, so it hops to main.
    func playEnvironmentalNoise(kind: Int) {
        guard isEnabled, isPhone else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if kind >= Config.envNoiseKindAltar {            // altar grind — heavy thud + a second tap
                self.altarGrindHaptics.impactOccurred(intensity: Config.altarGrindIntensity)
                self.altarGrindHaptics.prepare()
                DispatchQueue.main.asyncAfter(deadline: .now() + Config.altarGrindDoubleGap) { [weak self] in
                    guard let self = self else { return }
                    self.altarGrindHaptics.impactOccurred(intensity: Config.altarGrindIntensity)
                    self.altarGrindHaptics.prepare()
                }
            } else {                                          // trap click — one gentle tick
                self.trapClickHaptics.impactOccurred(intensity: Config.trapClickIntensity)
                self.trapClickHaptics.prepare()
            }
        }
    }
}

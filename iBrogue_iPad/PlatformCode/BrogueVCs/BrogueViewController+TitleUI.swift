//
//  BrogueViewController+TitleUI.swift
//  Brogue
//
//  Title-screen UI: the engine version chooser, the universal title options menu, and
//  the per-engine info panel. Extracted verbatim from BrogueViewController.swift as part
//  of splitting that file by function.
//

import UIKit

extension BrogueViewController {

    // MARK: - Version chooser (title-screen engine swap)

    private static let engineDefaultsKey = "selectedEngine"

    /// The engine to boot on launch — the last one played, defaulting to Brogue SE
    /// when the user hasn't picked one yet (fresh install / no stored preference).
    /// An explicit Classic choice is honored via the `"classic"` case; only a missing
    /// or unrecognized value falls through to SE.
    static func persistedEngine() -> EngineKind {
        switch UserDefaults.standard.string(forKey: engineDefaultsKey) {
        case "classic": return .classic
        case "ce": return .ce
        case "se": return .se
        default: return .se
        }
    }

    func persistEngine() {
        let value: String
        switch currentEngine {
        case .classic: value = "classic"
        case .ce: value = "ce"
        case .se: value = "se"
        }
        UserDefaults.standard.set(value, forKey: Self.engineDefaultsKey)
    }

    /// Builds the title-only "‹ engine ›" chip. Swipe or tap it to switch engines.
    func setupVersionChooser() {
        let chip = UIView()
        chip.translatesAutoresizingMaskIntoConstraints = false
        chip.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        chip.layer.cornerRadius = 16
        chip.isHidden = true

        let font = UIFont.monospacedSystemFont(ofSize: 17, weight: .semibold)
        let makeChevron: (String) -> UILabel = { text in
            let chevron = UILabel()
            chevron.text = text
            chevron.textColor = .white
            chevron.font = font
            return chevron
        }
        // The chip and these chevrons stay put; only `name` fades.
        let name = UILabel()
        name.textColor = .white
        name.font = font
        name.textAlignment = .center

        let stack = UIStackView(arrangedSubviews: [makeChevron("‹"), name, makeChevron("›")])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 14
        chip.addSubview(stack)

        view.addSubview(chip)
        NSLayoutConstraint.activate([
            chip.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            chip.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            stack.topAnchor.constraint(equalTo: chip.topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: chip.bottomAnchor, constant: -6),
            stack.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -16),
        ])

        // Swipe direction maps to the lineage cycle: left → next (Classic→CE→SE),
        // right → previous. A tap advances forward, same as a left swipe.
        let swipeLeft = UISwipeGestureRecognizer(target: self, action: #selector(versionChooserSwipedNext))
        swipeLeft.direction = .left
        chip.addGestureRecognizer(swipeLeft)
        let swipeRight = UISwipeGestureRecognizer(target: self, action: #selector(versionChooserSwipedPrev))
        swipeRight.direction = .right
        chip.addGestureRecognizer(swipeRight)
        chip.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(versionChooserActivated)))

        versionChooser = chip
        versionChooserLabel = name
        updateVersionChooserLabel()
    }

    @objc private func versionChooserActivated() {
        cycleEngine(forward: true)
    }

    @objc private func versionChooserSwipedNext() {
        cycleEngine(forward: true)
    }

    @objc private func versionChooserSwipedPrev() {
        cycleEngine(forward: false)
    }

    // MARK: - Title-screen options (universal, Classic + CE)

    /// Builds the lower-left options button. A single tap opens its menu; the
    /// button is title-only, shown/hidden alongside the version chooser.
    func setupOptionsButton() {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.tintColor = UIColor(white: 0.85, alpha: 1.0)
        button.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        button.layer.cornerRadius = 22
        button.setImage(UIImage(systemName: "gearshape.fill",
                                withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)),
                        for: .normal)
        button.isHidden = true
        button.showsMenuAsPrimaryAction = true
        button.menu = optionsMenu()

        view.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            button.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            button.widthAnchor.constraint(equalToConstant: 44),
            button.heightAnchor.constraint(equalToConstant: 44),
        ])
        optionsButton = button
    }

    /// Info button, placed just to the right of the options button. Matches the
    /// options button's styling. Tapping it presents a description of the
    /// currently selected engine's key features.
    func setupInfoButton() {
        guard let optionsButton = optionsButton else { return }
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.tintColor = UIColor(white: 0.85, alpha: 1.0)
        button.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        button.layer.cornerRadius = 22
        button.setImage(UIImage(systemName: "info.circle.fill",
                                withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)),
                        for: .normal)
        button.isHidden = true
        button.addTarget(self, action: #selector(infoButtonPressed), for: .touchUpInside)

        view.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: optionsButton.trailingAnchor, constant: 12),
            button.centerYAnchor.constraint(equalTo: optionsButton.centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: 44),
            button.heightAnchor.constraint(equalToConstant: 44),
        ])
        infoButton = button
    }

    @objc private func infoButtonPressed() {
        presentEngineInfo()
    }

    /// The options menu. Universal across engines; add new entries here.
    private func optionsMenu() -> UIMenu {
        let resetDirections = UIAction(title: "Default d-pad position",
                                       image: UIImage(systemName: "arrow.counterclockwise")) { [weak self] _ in
            self?.resetDpadPosition()
        }

        var children: [UIMenuElement] = []

        // Haptics and magnifier orientation are iPhone-only: iPad has no haptic
        // engine, and the beside-the-finger magnifier placement is iPhone-only.
        if UIDevice.current.userInterfaceIdiom == .phone {
            let haptics = UIAction(title: "Haptics",
                                   image: UIImage(systemName: "iphone.radiowaves.left.and.right"),
                                   state: hapticsController.isEnabled ? .on : .off) { [weak self] _ in
                self?.toggleHaptics()
            }
            // Title states the current side (left-handed mode = magnifier on the
            // right); no checkmark, since the text itself conveys the state.
            let magnifierSide = UIAction(title: leftHandMagnifier ? "Magnifier: right side" : "Magnifier: left side",
                                         image: UIImage(systemName: "magnifyingglass")) { [weak self] _ in
                self?.toggleLeftHandMagnifier()
            }
            children.append(contentsOf: [haptics, magnifierSide])
            // Pinch-to-zoom is always on; this sub-option zooms out to show a tapped
            // sidebar entity's description box so it isn't clipped while zoomed.
            let examineZoom = UIAction(title: "Zoom out on examine",
                                       image: UIImage(systemName: "sidebar.left"),
                                       state: examineZoomEnabled ? .on : .off) { [weak self] _ in
                self?.toggleExamineZoom()
            }
            children.append(examineZoom)
            // Extends the magnified map behind the translucent interface (sidebar, message
            // log, flavor line), and lets a held-magnifier drag reach the cells behind it.
            let mapUnderSidebar = UIAction(title: "Map behind interface",
                                           image: UIImage(systemName: "rectangle.inset.filled"),
                                           state: mapUnderSidebarEnabled ? .on : .off) { [weak self] _ in
                self?.toggleMapUnderSidebar()
            }
            children.append(mapUnderSidebar)
            // Magnification applied to the title / menu / inventory panels (iPhone menu magnify).
            // The value is the max scale; 1.0× turns it off. Stepped submenu over the useful range
            // (a slider can't live in a UIMenu, and 5 steps are easier to hit than a tiny slider).
            let current = BrogueViewController.menuMagnifyScaleSetting
            let steps: [CGFloat] = [1.0, 1.1, 1.2, 1.3, 1.4]   // explicit to avoid FP stride drift
            let sizeItems: [UIMenuElement] = steps.map { step in
                UIAction(title: String(format: "%.1f×", Double(step)),
                         state: abs(step - current) < 0.05 ? .on : .off) { [weak self] _ in
                    self?.setMenuMagnifyScale(step)
                }
            }
            children.append(UIMenu(title: "Menu size",
                                   image: UIImage(systemName: "textformat.size"),
                                   children: sizeItems))
        }

        children.append(resetDirections)
        return UIMenu(title: "Options", children: children)
    }

    /// Flips the left-handed magnifier setting, persists it, applies it to the
    /// live magnifier, and rebuilds the menu so its checkmark updates.
    private func toggleLeftHandMagnifier() {
        leftHandMagnifier.toggle()
        UserDefaults.standard.set(leftHandMagnifier, forKey: BrogueViewController.leftHandMagnifierDefaultsKey)
        magView.leftHandMode = leftHandMagnifier
        hapticsController.fireButton()
        optionsButton?.menu = optionsMenu()
    }

    /// Flips "zoom out on examine" (sidebar-tap description), persists it, and rebuilds
    /// the menu. If turned off mid-examine, restore the zoom immediately.
    private func toggleExamineZoom() {
        examineZoomEnabled.toggle()
        UserDefaults.standard.set(examineZoomEnabled, forKey: RogueScene.examineZoomEnabledDefaultsKey)
        if !examineZoomEnabled {                            // drops any active/pending examine suspend
            examineArmDebounce?.cancel()
            examineArmed = false
        }
        hapticsController.fireButton()
        optionsButton?.menu = optionsMenu()
    }

    /// Flips "map under sidebar" (translucent sidebar + full-width zoomed map + held-
    /// magnifier reach), persists it, applies it to the live scene (restoring the opaque
    /// sidebar at once if turned off mid-zoom), and rebuilds the menu.
    private func toggleMapUnderSidebar() {
        mapUnderSidebarEnabled.toggle()
        UserDefaults.standard.set(mapUnderSidebarEnabled, forKey: RogueScene.mapUnderSidebarEnabledDefaultsKey)
        skViewPort.rogueScene.setMapUnderSidebarEnabled(mapUnderSidebarEnabled)
        hapticsController.fireButton()
        optionsButton?.menu = optionsMenu()
    }

    /// Sets the menu-magnify scale (Options ▸ Menu size), persists it, rebuilds the menu so the
    /// checkmark updates, and re-applies live to the currently-shown menu (the title menu is up
    /// while Options is open) at the new scale. 1.0× tears the magnify down (menus render at 1×).
    private func setMenuMagnifyScale(_ scale: CGFloat) {
        UserDefaults.standard.set(Double(scale), forKey: BrogueViewController.menuScaleDefaultsKey)
        hapticsController.fireButton()
        optionsButton?.menu = optionsMenu()
        applyMenuMagnify()   // re-fit the current menuBox at the new scale (or tear down at 1.0×)
    }

    /// Flips the haptics setting, persists it, gives confirming feedback if it was
    /// just enabled, and rebuilds the menu so its checkmark reflects the new state.
    private func toggleHaptics() {
        hapticsController.setEnabled(!hapticsController.isEnabled)
        optionsButton?.menu = optionsMenu()
    }

    /// Clears the saved two-finger-drag offset so the directional pad returns to
    /// its default position. Universal — the offset is shared by Classic and CE.
    private func resetDpadPosition() {
        hapticsController.fireButton()
        dpadUserOffset = .zero
        saveDpadOffset()
        applyDpadTransform()
    }

    func updateTitleOptionsVisibility() {
        optionsButton?.isHidden = !atTitle
        infoButton?.isHidden = !atTitle
    }

    // MARK: - Engine info panel

    /// Returns a bold variant of the font, preserving its (Dynamic Type) size.
    private static func boldFont(_ font: UIFont) -> UIFont {
        guard let descriptor = font.fontDescriptor.withSymbolicTraits(.traitBold) else { return font }
        return UIFont(descriptor: descriptor, size: 0)
    }

    /// Returns an italic variant of the font, preserving its (Dynamic Type) size.
    private static func italicFont(_ font: UIFont) -> UIFont {
        guard let descriptor = font.fontDescriptor.withSymbolicTraits(.traitItalic) else { return font }
        return UIFont(descriptor: descriptor, size: 0)
    }

    /// A line in the info panel. The renderer styles each kind differently.
    private enum InfoBlock {
        case heading(String)        // top-level group heading
        case note(String)           // italic descriptor beneath a heading
        case section(String)        // sub-section heading
        case body(String)           // plain body paragraph
        case bullets([String])      // bullet list
        case link(String, String)   // tappable label + destination URL
    }

    /// Presents a scrollable description of the currently selected engine's key
    /// features. Content is engine-aware: CE summarizes how it differs from the
    /// original Brogue; Classic gives a short description of the original game.
    private func presentEngineInfo() {
        guard presentedViewController == nil else { return }

        let title: String
        let blocks: [InfoBlock]
        switch currentEngine {
        case .classic: title = "About Brogue";    blocks = Self.classicInfoBlocks()
        case .ce:      title = "About BrogueCE";   blocks = Self.ceInfoBlocks()
        case .se:      title = "About Brogue SE";  blocks = Self.seInfoBlocks()
        }

        let content = UIViewController()
        content.view.backgroundColor = .systemBackground
        content.title = title
        content.navigationItem.rightBarButtonItem =
            UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(dismissEngineInfo))

        let textView = UITextView()
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = false
        textView.isSelectable = true          // required for .link attributes to be tappable
        textView.alwaysBounceVertical = true
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 12, bottom: 24, right: 12)
        textView.linkTextAttributes = [
            .foregroundColor: UIColor.link,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        textView.attributedText = BrogueViewController.infoAttributedText(blocks)
        content.view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: content.view.safeAreaLayoutGuide.topAnchor),
            textView.bottomAnchor.constraint(equalTo: content.view.bottomAnchor),
            textView.leadingAnchor.constraint(equalTo: content.view.safeAreaLayoutGuide.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: content.view.safeAreaLayoutGuide.trailingAnchor),
        ])

        let nav = UINavigationController(rootViewController: content)
        present(nav, animated: true)
    }

    @objc private func dismissEngineInfo() {
        dismiss(animated: true)
    }

    /// Renders the structured info blocks into a styled attributed string,
    /// scaling with the user's Dynamic Type setting.
    private static func infoAttributedText(_ blocks: [InfoBlock]) -> NSAttributedString {
        let out = NSMutableAttributedString()

        let bulletStyle = NSMutableParagraphStyle()
        bulletStyle.headIndent = 16
        bulletStyle.firstLineHeadIndent = 0
        bulletStyle.paragraphSpacing = 7
        bulletStyle.lineBreakMode = .byWordWrapping
        bulletStyle.tabStops = [NSTextTab(textAlignment: .left, location: 16)]

        let headingStyle = NSMutableParagraphStyle()
        headingStyle.paragraphSpacingBefore = 18
        headingStyle.paragraphSpacing = 4

        let sectionStyle = NSMutableParagraphStyle()
        sectionStyle.paragraphSpacingBefore = 12
        sectionStyle.paragraphSpacing = 4

        let bodyStyle = NSMutableParagraphStyle()
        bodyStyle.paragraphSpacing = 8
        bodyStyle.lineBreakMode = .byWordWrapping

        for block in blocks {
            switch block {
            case .heading(let text):
                out.append(NSAttributedString(string: text + "\n", attributes: [
                    .font: boldFont(UIFont.preferredFont(forTextStyle: .title2)),
                    .foregroundColor: UIColor.label,
                    .paragraphStyle: headingStyle,
                ]))
            case .note(let text):
                out.append(NSAttributedString(string: text + "\n", attributes: [
                    .font: italicFont(UIFont.preferredFont(forTextStyle: .subheadline)),
                    .foregroundColor: UIColor.secondaryLabel,
                ]))
            case .section(let text):
                out.append(NSAttributedString(string: text + "\n", attributes: [
                    .font: UIFont.preferredFont(forTextStyle: .headline),
                    .foregroundColor: UIColor.label,
                    .paragraphStyle: sectionStyle,
                ]))
            case .body(let text):
                out.append(NSAttributedString(string: text + "\n", attributes: [
                    .font: UIFont.preferredFont(forTextStyle: .body),
                    .foregroundColor: UIColor.label,
                    .paragraphStyle: bodyStyle,
                ]))
            case .bullets(let items):
                for item in items {
                    out.append(NSAttributedString(string: "•\t" + item + "\n", attributes: [
                        .font: UIFont.preferredFont(forTextStyle: .body),
                        .foregroundColor: UIColor.label,
                        .paragraphStyle: bulletStyle,
                    ]))
                }
            case .link(let text, let urlString):
                var attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.preferredFont(forTextStyle: .body),
                    .paragraphStyle: bodyStyle,
                ]
                // The .link attribute drives both tap handling and the styling from
                // the text view's linkTextAttributes; fall back to plain body text
                // if the URL is somehow unparseable rather than dropping the line.
                if let url = URL(string: urlString) {
                    attributes[.link] = url
                } else {
                    attributes[.foregroundColor] = UIColor.label
                }
                out.append(NSAttributedString(string: text + "\n", attributes: attributes))
            }
        }
        return out
    }

    /// BrogueCE's purpose and how it relates to the original Brogue. Curated for
    /// the iOS port; the full change list lives in the project changelog/wiki.
    private static func ceInfoBlocks() -> [InfoBlock] {
        return [
            .link("BrogueCE support", "https://github.com/tmewett/BrogueCE"),
            .link("iOS support", "https://github.com/sethhoward/Brogue-iPad"),
            .note("Brogue was created by Brian Walker. This version, Brogue: Community Edition, is a continuation of its development. It has several main goals:"),
            .bullets([
                "fix bugs and crashes",
                "add useful quality of life and non-gameplay features",
                "improve the gameplay and keep it exciting",
                "ease development and maintenance",
                "be a convenient base for forks and ports to new platforms",
            ]),
            .section("How is CE different from the original Brogue?"),
            .note("Please refer to the changelog or release history for a complete list:"),
            .link("Changes from original", "https://github.com/tmewett/BrogueCE/wiki/Changes-from-original"),
        ]
    }

    /// Brogue SE release notes — player-facing highlights for the current release,
    /// followed by every prior release archived under a "📦 Previous Release —" heading.
    /// Curated for the info panel; the full technical log lives in
    /// BrogueSE/Engine/IOS_MODIFICATIONS.md. When shipping a new release, PREPEND the new
    /// section and DEMOTE the current one to a Previous Release block — never delete an old
    /// release; the full history is intentionally kept here. Keep in sync with new content.
    private static func seInfoBlocks() -> [InfoBlock] {
        return [
            .link("Support", "https://github.com/sethhoward/Brogue-iPad"),
            .note("Brogue SE — an experimental fork of BrogueCE with original items, monsters, and mechanics. Release 0.12.0, \"C is for Curses\", turns cursed gear from a dead end into a decision — a cursed runic now pairs a real, always-on power with its bite — and adds a shrine that will identify your pack, if you dare wake what guards it. Here's what's new:"),
            .heading("🔮 Cursed Runics, Reworked"),
            .bullets([
                "A curse is a bargain, not a trap — A cursed runic now grants a genuine, always-on power alongside its drawback, welded to you until you deal with it. Every downside has a counter you can lean into, so keeping a cursed item can be the smart play.",
                "Two ways to break the weld — Pour enchant scrolls in to the purify threshold and the drawback burns away while the power stays (weapons at +6, armor at +4); or read remove-curse to pry it off early, drawback and all.",
                "Maddening, reckless, and clumsy blades — Delirium confounds what you strike but leaves you hallucinating; Recklessness trades the damage you take for the damage you deal; a Clumsy blade fumbles and stuns you — until you purify it into a true executioner's blade.",
                "Anchor, Smoky, and Acrophobia armor — Anchor steels your defense but drags your step (purify to stand immovable); Smoky armor wraps you in concealing haze at the cost of your own sight (purify for a quiet stealth aura); Acrophobia makes you fearless of pits but dizzy at their edge.",
            ]),
            .heading("🗿 Altars of Divination"),
            .bullets([
                "Reveal your unknowns — A new shrine replaces the Altar of Insight, watched over by a looming statue, fully identifies any unidentified item you set on one of its altars — and the first one is always safe.",
                "Press your luck — Each further item you reveal risks waking the statue's guardian, and the greedier you get the deadlier it is: Take what you dare.",
            ]),
            .heading("🎣 Cleaner Distractions"),
            .bullets([
                "Thrown lures buy real time — A monster that goes to investigate a thrown item now lingers over it for a few turns before losing interest, opening a genuine window to slip past.",
            ]),
            .heading("🎮 Quality of Life"),
            .bullets([
                "Fire no longer rattles you — Catching fire used to throw you into a brief panic; now that disorientation strikes only monsters. It still burns — but your wits, and your next move, stay yours.",
                "Study a scroll even while hunted — Sitting down to a meal always lets you puzzle out an unidentified scroll now, even with something on your trail; the old \"only when nothing's hunting you\" restriction is gone.",
            ]),
            .heading("📦 Previous Release — 0.11.0 \"B is for Balance\""),
            .note("Retuned the arsenal — heavier trade-offs on weapons, staffs, and rings, with clearer status tells to read the fight at a glance:"),
            .heading("⚖️ Balance Pass"),
            .bullets([
                "Broadsword & war axe, soft-capped — The two late-game staples no longer scale forever: enchanting pays full value only through +10, and each point beyond returns about a quarter of its old kick. Still top-tier, no longer an automatic win.",
                "War pike, slowed — The pike's strength was always its throughput — reach-2 and a thrust that pierces a whole line — so it now takes twice as long to recover after each attack. Trade tempo for that reach.",
                "Flail, less of a lawnmower — The flail's signature hits on enemies you sweep past while moving now land for half damage, so wading through a crowd isn't free.",
                "Bare-knuckle scaling — Unarmed attacks now grow with your strength, so being caught between weapons isn't hopeless.",
                "Staffs come into their own — Lightning and firebolt get a real power bump once enchanted to +5 and beyond, rewarding committing to a single staff or a hybrid heavy weapon and stave approach.",
                "Ring of Transference, reworked — It now drains life from whatever you strike and bleeds a share of your own harmful afflictions onto the target — turning your suffering against your enemy.",
            ]),
            .heading("💨 Smoke & Terrain"),
            .bullets([
                "Where there's fire, there's smoke — Burning terrain now breathes a vision-obscuring haze that drifts and thins over time, so a blaze can blind as much as it burns.",
                "Traps suit their surroundings — Fire traps nestle in dry grass, caustic traps among scattered bones — the dungeon hints at what's waiting.",
                "Douse the burning — Fiery creatures are snuffed out by water or frost, so the right element can put out a walking bonfire.",
            ]),
            .heading("👁️ Tells & Legibility"),
            .bullets([
                "Read the battlefield — A small glyph now blinks over any creature (and you) that's confused, burning, stunned, protected, hasted, or healing, so you can size up the situation.",
                "Clairvoyance reads the floor — On arriving at a new depth, a worn Ring of Clairvoyance senses whether items on the level are helpful or harmful — as many as the ring's enchant level.",
                "A sharper ear — The noise system is clearer: a pack raises a rallying cry when one of them rouses the others, submerged creatures fall silent, and close threats are easier to hear.",
            ]),
            .heading("📦 Previous Release — 0.10.0 \"A Is For AAaAH!\""),
            .note("The sound update — the dungeon learned to hear you, and you learned to hear it:"),
            .heading("🔊 The Dungeon Can Hear You"),
            .bullets([
                "Make noise, get noticed — Footsteps, fighting, and the terrain you cross all send sound rippling through the dungeon. It bends around corners and muffles through closed doors, so unseen monsters can now hear you coming and slip away to investigate the racket.",
                "Every weapon has a voice — A dagger is nearly silent; a war hammer is a clamor. Light armor and wading keep you quiet, while heavy armor and crunching over rubble give you away.",
                "Hear what you can't see — When something stirs off-screen, a ripple shows roughly where it was, and a \"?\" marks a creature that heard you and is closing in. Stay still and it may pass; bolt and you'll draw a crowd.",
                "A louder world — Traps click, reward-room cages slam and machinery grinds, stone guardians boom with every step, and an alarm trap's shriek now echoes across the entire floor.",
                "Throw to distract — Hurl an item to lure investigating monsters to where it lands. The catch: the distraction is consumed when they arrive, so every diversion costs you the item.",
                "The Ring of Awareness now hears, too — Once just a sense for traps, secret doors, and hidden levers, it now also sharpens your ears: you catch unseen creatures stirring nearby, and the more powerful the ring, the farther off — and more reliably — you hear them. (Cursed rings dull your hearing instead.)",
            ]),
            .heading("🐺 Lone Wolf"),
            .bullets([
                "Go it alone — Adventuring with no allies builds Lone Wolf tiers (up to five), each hardening you with extra effective strength. Take on a single companion and the bond breaks, resetting the track — the dungeon rewards the truly solitary.",
            ]),
            .heading("🎮 Quality of Life"),
            .bullets([
                "Re-zap your last staff — Press \"A\" (modern keyboard layout) or set it to a quick action button to re-apply the staff you used last, mirroring re-throw.",
                "Quiet, please — A new menu toggle hides your own sound-ripple animation while leaving every other noise effect intact.",
                "OS-proof saves — If iOS kills the app while it's in the background, your run reloads right where you left off.",
                "iPhone haptics — Feel a pulse when something hears you, and a heavier thump when a loud event goes off.",
                "Refined identification — Detect magic and resting now surface the items you still haven't figured out first before fully identifying ones you already know polarity, and a worn Ring of Wisdom learns your armor and rings faster.",
            ]),
            .heading("📦 Previous Release — 0.9.0 \"Alphabet-a Soup\""),
            .note("The first Brogue SE release, which introduced original items, monsters, and mechanics:"),
            .heading("🧪 New Items"),
            .bullets([
                "The Empty Bottle — Carry it and the world fills it: step into a gas or pool to bottle it, drift over lava or a chasm while levitating to skim it, or set it down and zap it with a bolt. Each capture becomes a real, identified potion.",
                "Captured potions — Acid, webbing, steam, ice, and water can only be obtained by capturing hazards with the empty bottle. Each one re-creates its hazard when thrown.",
                "Staff of Frost — Freeze enemies solid, slow them, freeze water into walkable ice bridges, turn foliage into brittle frozen walls, and shove foes back moving them out of your way and damaging enemies in their path.",
            ]),
            .heading("👹 Monsters & Allies"),
            .bullets([
                "The Gold Goblin — A skittish treasure-hoarder that flees toward the stairs, scattering a trail of gold. Chase it down and corner it before it escapes to the next floor.",
                "Cleverer thieves — Monkeys and imps now target the items they actually covet, not just whatever's handy.",
                "Better allies — Allies keep a safe distance from invulnerable monsters, and the Ring of Light can rally and embolden the companions fighting beside you.",
            ]),
            .heading("🔍 A New Way to Identify Items"),
            .bullets([
                "Rest to learn — Resting gradually reveals whether your unidentified items are helpful or harmful.",
                "Clues add up — Gather enough hints about an item — or rule out enough of the alternatives — and the dungeon puts it together for you, identifying it outright.",
                "Detect magic, reined in — The potion of detect magic now only hints at the good-or-bad nature of couple of items instead of all, and turns up less often than before. But pair it with a Ring of Wisdom and the potion becomes stronger.",
                "Altars of Insight — Sacrifice one item to reveal the nature of another.",
                "Everyday tells — Eating a meal, watching a scroll burn, shattering a potion with a thrown weapon or a bolt, freeing a captive, and the rings of awareness and wisdom all quietly reveal clues about what you're carrying.",
            ]),
            .heading("🌊 The Living Dungeon"),
            .bullets([
                "Electrified water — A lightning bolt striking a pool now shocks the entire connected body of water. Mind where you stand.",
                "Water has uses — Wading washes away the scent trail you leave for hunters and douses flames.",
                "Fire spreads consequences — Catching fire sends you into a brief panic; food rations caught in fire cook into edible \"cooked food.\"",
                "Read the chase — You can now sense when a pursuing monster has lost your trail.",
            ]),
            .heading("🎮 Quality of Life"),
            .bullets([
                "Potions float away when thrown into deep water",
                "Pick your controls — Choose between Classic and Modern keyboard layouts; the game adapts when a hardware keyboard is attached.",
                "Pick up where you left off — Your last-played seed is remembered across launches.",
                "Smoother and more stable — Numerous community bug fixes, from dungeon-generation quirks to combat, stealth, and identification edge cases (#766, #805, #812, #816, #831, #837, #841).",
                "..and so much more",
            ]),
        ]
    }

    /// Short description of the original Brogue (the "Classic" engine).
    private static func classicInfoBlocks() -> [InfoBlock] {
        return [
            .link("Support", "https://github.com/sethhoward/Brogue-iPad"),
            .note("Countless adventurers before you have descended this torch-lit staircase, seeking the promised riches below. As you reach the bottom and step into the wide cavern, the doors behind you seal with a powerful magic..."),
            .heading("Welcome to the Dungeons of Doom!"),
            .body("Brogue is a single-player strategy game set in the halls of a mysterious and randomly-generated dungeon. The objective is simple enough -- retrieve the fabled Amulet of Yendor from the 26th level -- but the dungeon is riddled with danger. Horrifying creatures and devious, trap-ridden terrain await. Yet it is also riddled with weapons, potions, and artifacts of forgotten power. Survival demands strength and cunning in equal measure as you descend, making the most of what the dungeon gives you. You will make sacrifices, narrow escapes, and maybe even some friends along the way -- but will you be one of the lucky few to return alive?"),
        ]
    }

    func updateVersionChooserLabel() {
        switch currentEngine {
        case .classic: versionChooserLabel?.text = "Brogue"
        case .ce:      versionChooserLabel?.text = "BrogueCE"
        case .se:      versionChooserLabel?.text = "Brogue SE"
        }
    }

    func updateVersionChooserVisibility() {
        updateVersionChooserLabel()
        if atTitle {
            versionChooser?.isHidden = false
            showVersionChooserName()
        } else {
            versionChooserFadeTimer?.invalidate()
            versionChooser?.isHidden = true
        }
    }

    /// Shows the engine name briefly, then fades just the name out — the chip and
    /// its ‹ › chevrons stay visible so the affordance remains.
    private func showVersionChooserName() {
        guard let name = versionChooserLabel else { return }
        versionChooserFadeTimer?.invalidate()
        UIView.animate(withDuration: 0.2) { name.alpha = 1 }
        versionChooserFadeTimer = Timer.scheduledTimer(withTimeInterval: 3.5, repeats: false) { [weak self] _ in
            guard let name = self?.versionChooserLabel else { return }
            UIView.animate(withDuration: 0.6) { name.alpha = 0 }
        }
    }
}

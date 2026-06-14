//
//  FileManagementViewController.swift
//  iBrogue_iPad
//
//  This file is part of Brogue.
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU Affero General Public License as
//  published by the Free Software Foundation, either version 3 of the
//  License, or (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU Affero General Public License for more details.
//
//  You should have received a copy of the GNU Affero General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

import UIKit

/// Lists the player's saved games (`.broguesave`) and replays (`.broguerec`) from
/// the app's Documents folder and lets them delete or share each file via swipe
/// actions. Loading and replaying remain the job of the C engine's title menu —
/// this screen is purely for managing files the engine has no way to clean up.
///
/// Files are shown as-is, including the `LastGame`/`LastRecording` auto-checkpoints.
final class FileManagementViewController: UITableViewController {

    private enum Section: Int, CaseIterable {
        case saves
        case replays

        var title: String {
            switch self {
            case .saves:   return "Saves"
            case .replays: return "Replays"
            }
        }

        /// Footer shown when the section is empty.
        var emptyMessage: String {
            switch self {
            case .saves:   return "No saved games"
            case .replays: return "No recordings"
            }
        }

        var fileExtension: String {
            switch self {
            case .saves:   return "broguesave"
            case .replays: return "broguerec"
            }
        }
    }

    private var files: [Section: [URL]] = [.saves: [], .replays: []]

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    /// Directory whose `.broguesave`/`.broguerec` files are listed. Defaults to
    /// the flat Documents folder (Classic's saves); CE passes Documents/ce.
    private let directoryURL: URL

    init(directory: URL? = nil) {
        self.directoryURL = directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        self.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        super.init(coder: coder)
    }

    /// Bottom-toolbar button (shown only in editing mode) that deletes every
    /// selected file at once.
    private lazy var deleteSelectedButton = UIBarButtonItem(
        title: "Delete", style: .plain, target: self, action: #selector(deleteSelectedTapped))

    /// Bottom-toolbar button (editing mode) that offers a per-section
    /// "delete all" via an action sheet — clears all Saves or all Replays.
    private lazy var deleteAllButton = UIBarButtonItem(
        title: "Delete All", style: .plain, target: self, action: #selector(deleteAllTapped))

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Manage Files"
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .close, target: self, action: #selector(doneTapped))
        navigationItem.leftBarButtonItem = editButtonItem
        tableView.allowsMultipleSelectionDuringEditing = true
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadFiles()
    }

    @objc private func doneTapped() {
        dismiss(animated: true)
    }

    // MARK: - Data

    private func reloadFiles() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []

        for section in Section.allCases {
            files[section] = urls
                .filter { $0.pathExtension == section.fileExtension }
                .sorted { modificationDate(of: $0) > modificationDate(of: $1) }
        }
        tableView.reloadData()
    }

    private func modificationDate(of url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
    }

    private func file(at indexPath: IndexPath) -> URL? {
        guard let section = Section(rawValue: indexPath.section),
              let list = files[section], indexPath.row < list.count else {
            return nil
        }
        return list[indexPath.row]
    }

    // MARK: - Table view data source

    override func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard let section = Section(rawValue: section) else { return 0 }
        return files[section]?.count ?? 0
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        Section(rawValue: section)?.title
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard let section = Section(rawValue: section),
              files[section]?.isEmpty ?? true else { return nil }
        return section.emptyMessage
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "file")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "file")

        if let url = file(at: indexPath) {
            var content = UIListContentConfiguration.subtitleCell()
            content.text = url.deletingPathExtension().lastPathComponent
            content.secondaryText = dateFormatter.string(from: modificationDate(of: url))
            cell.contentConfiguration = content
        }
        return cell
    }

    // MARK: - Swipe actions

    override func tableView(_ tableView: UITableView,
                            trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath)
    -> UISwipeActionsConfiguration? {
        guard let url = file(at: indexPath) else { return nil }

        let delete = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, completion in
            self?.confirmDelete(url: url, at: indexPath, completion: completion)
        }

        let share = UIContextualAction(style: .normal, title: "Share") { [weak self] _, _, completion in
            self?.share(url: url, from: indexPath)
            completion(true)
        }
        share.backgroundColor = .systemBlue

        return UISwipeActionsConfiguration(actions: [delete, share])
    }

    private func confirmDelete(url: URL, at indexPath: IndexPath, completion: @escaping (Bool) -> Void) {
        let name = url.deletingPathExtension().lastPathComponent
        let alert = UIAlertController(
            title: "Delete “\(name)”?",
            message: "This cannot be undone.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completion(false) })
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            self?.delete(url: url, at: indexPath)
            completion(true)
        })
        present(alert, animated: true)
    }

    private func delete(url: URL, at indexPath: IndexPath) {
        removeFile(at: url)
        guard let section = Section(rawValue: indexPath.section) else { return }
        files[section]?.remove(at: indexPath.row)
        // Reload the whole section so the empty-state footer appears once the
        // last row in it is gone.
        tableView.reloadSections(IndexSet(integer: indexPath.section), with: .automatic)
    }

    /// Deletes a file and the companion annotation (.txt) recordings may carry
    /// alongside. Shared by swipe-to-delete and batch delete; does not touch the UI.
    private func removeFile(at url: URL) {
        try? FileManager.default.removeItem(at: url)
        let annotation = url.deletingPathExtension().appendingPathExtension("txt")
        if FileManager.default.fileExists(atPath: annotation.path) {
            try? FileManager.default.removeItem(at: annotation)
        }
    }

    private func share(url: URL, from indexPath: IndexPath) {
        let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        // Anchor the popover to the row so it presents correctly on iPad.
        if let popover = activity.popoverPresentationController,
           let cell = tableView.cellForRow(at: indexPath) {
            popover.sourceView = cell
            popover.sourceRect = cell.bounds
        }
        present(activity, animated: true)
    }

    // MARK: - Editing mode (multi-select batch delete)

    override func setEditing(_ editing: Bool, animated: Bool) {
        super.setEditing(editing, animated: animated)
        if editing {
            let flexible = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
            deleteSelectedButton.tintColor = .systemRed
            deleteAllButton.tintColor = .systemRed
            toolbarItems = [deleteAllButton, flexible, deleteSelectedButton]
            updateToolbarButtonStates()
        }
        navigationController?.setToolbarHidden(!editing, animated: animated)
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        if isEditing {
            updateToolbarButtonStates()
        } else {
            // No tap action outside editing — clear the transient selection.
            tableView.deselectRow(at: indexPath, animated: false)
        }
    }

    override func tableView(_ tableView: UITableView, didDeselectRowAt indexPath: IndexPath) {
        if isEditing { updateToolbarButtonStates() }
    }

    private func updateToolbarButtonStates() {
        let count = tableView.indexPathsForSelectedRows?.count ?? 0
        deleteSelectedButton.isEnabled = count > 0
        deleteSelectedButton.title = count > 0 ? "Delete (\(count))" : "Delete"

        // "Delete All" is independent of selection — enabled whenever any file exists.
        let total = files.values.reduce(0) { $0 + $1.count }
        deleteAllButton.isEnabled = total > 0
    }

    @objc private func deleteSelectedTapped() {
        guard let selected = tableView.indexPathsForSelectedRows, !selected.isEmpty else { return }
        let count = selected.count
        let alert = UIAlertController(
            title: "Delete \(count) file\(count == 1 ? "" : "s")?",
            message: "This cannot be undone.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            self?.deleteSelected(selected)
        })
        present(alert, animated: true)
    }

    private func deleteSelected(_ indexPaths: [IndexPath]) {
        // Resolve URLs before mutating, since deletion reshuffles the arrays.
        for url in indexPaths.compactMap({ file(at: $0) }) {
            removeFile(at: url)
        }
        reloadFiles()
        setEditing(false, animated: true)
    }

    // MARK: - Delete all (per section)

    /// Action sheet offering one destructive "delete all" per non-empty section.
    /// The sheet selection is the confirmation (standard for bulk delete); each
    /// option names the section and its file count so the choice is unambiguous.
    @objc private func deleteAllTapped() {
        let alert = UIAlertController(
            title: "Delete All Files",
            message: "This cannot be undone.",
            preferredStyle: .actionSheet)
        for section in Section.allCases {
            let count = files[section]?.count ?? 0
            guard count > 0 else { continue }
            alert.addAction(UIAlertAction(
                title: "Delete All \(section.title) (\(count))",
                style: .destructive) { [weak self] _ in
                    self?.deleteAll(in: section)
            })
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        // Anchor for iPad's popover presentation.
        alert.popoverPresentationController?.barButtonItem = deleteAllButton
        present(alert, animated: true)
    }

    private func deleteAll(in section: Section) {
        for url in files[section] ?? [] {
            removeFile(at: url)
        }
        reloadFiles()
        updateToolbarButtonStates()
    }
}

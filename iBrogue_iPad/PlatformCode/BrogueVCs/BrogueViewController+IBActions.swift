//
//  BrogueViewController+IBActions.swift
//  Brogue
//
//  Storyboard @IBAction handlers for the on-screen buttons (esc, inventory,
//  leaderboard, seed). Extracted verbatim from BrogueViewController.swift as part
//  of splitting that file by function.
//

import UIKit

extension BrogueViewController {
    @IBAction func escButtonPressed(_ sender: Any) {
        addKeyEvent(event: kESC_Key)
        inputTextField.resignFirstResponder()
        escButtonWanted = false
        refreshEscButtonVisibility()
    }
    
    @IBAction func showInventoryButtonPressed(_ sender: Any) {
        addKeyEvent(event: "i".ascii)
    }
    
    @IBAction func showLeaderBoardButtonPressed(_ sender: Any) {
        NSLog("[GameCenter] leaderboard button pressed")
        let boardID = (currentEngine == .ce) ? GameCenter.ceHighScoreLeaderboardID
                                              : GameCenter.highScoreLeaderboardID
        GameCenter.shared.showLeaderboard(id: boardID, from: self)
    }
    
    @IBAction func seedButtonPressed(_ sender: Any) {
        seedKeyDown = !seedKeyDown
        
        if seedKeyDown {
            let image = UIImage(named: "brogue_sproutedseed.png")
            seedButton.setImage(image, for: .normal)
        } else {
            let image = UIImage(named: "brogue_seed.png")
            seedButton.setImage(image, for: .normal)
        }
    }
}

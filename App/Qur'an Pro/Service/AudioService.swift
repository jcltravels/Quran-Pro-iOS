//
//  AudioService.swift
//  Qur'an Pro
//
//  Created by Adil Ben Moussa on 10/27/15.
//  Copyright © 2015 https://github.com/adilbenmoussa All rights reserved.
//  GNU GENERAL PUBLIC LICENSE https://raw.githubusercontent.com/adilbenmoussa/Quran-Pro-iOS/master/LICENSE
//

import Foundation
import AVFoundation
import MediaPlayer

struct Repeats {
    var verses = ["Play verse once".local, "Play verse twice".local, "Play 3 times".local, "Play 4 times".local, "Play 5 times".local, "Play 10 times".local, "Play 15 times".local, "Play 20 times", "Play 25 times".local, "Keep playing verse".local]
    var chapters = ["Play chapter by chapter".local, "Play chapter once".local, "Play chapter twice".local, "Play chapter 3 times".local, "Play chapter 4 times".local, "Play chapter 5 times".local, "Play chapter 10 times".local, "Play chapter 15 times".local, "Play chapter 20 times".local, "Play chapter 25 times".local, "Keep playing chapter".local]
    var verseCount: Int = 1
    var chapterCount: Int = 1
    var speedCount: Int = 1
}

protocol AudioDelegate {
    func playNextChapter()
    func scrollToVerse(_ verseId: Int, searchText:String?)
}

private let _AudioServiceSharedInstance = AudioService()

class AudioService:NSObject, AVAudioPlayerDelegate {
    
    @objc class func sharedInstance() -> AudioService {
        return _AudioServiceSharedInstance
    }
    
    //hold a reference to a delegate
    var delegate: AudioDelegate?
    var currentVerseIndex: Int!
    var isPaused: Bool!
    var abRepeatStartIndex: Int!
    var abRepeatEndIndex: Int!

    // A-B repeat state machine
    private enum ABPhase { case introNewVerse, playSequence }
    private var abPhase: ABPhase = .introNewVerse
    // The index of the "new" verse currently being introduced in this phase
    private var abPhaseNewVerseIndex: Int = 0
    // How many times we've played the current accumulated sequence
    private var abSequenceRepeatCount: Int = 0
    // Whether A-B repeat mode is currently active
    private var isABRepeatActive: Bool = false

    
    //hold the repeat verses and chapters string
    var repeats: Repeats!
    
    //hold the player instance
    fileprivate var player: AVAudioPlayer?
    
    override init(){
        super.init()
        self.isPaused = false
        self.repeats = Repeats()
        self.currentVerseIndex = 0
        self.abRepeatStartIndex = -1
        self.abRepeatEndIndex = -1
        self.isABRepeatActive = false
    }

    func initDelegation(_ delegate: AudioDelegate?){
        if delegate != nil {
            self.delegate = delegate
        }
    }

    @objc func setPlayVerse(_ verseToPlay: Verse? = nil) {
        if let verse = verseToPlay {
            self.currentVerseIndex = dollar.currentChapter.verses.index(of: verse) ?? 0
        }
    }
    
    //play the passed verse index
    //@param verseToPlay verse to play or the first one if nothing is passed
    @objc func play(_ verseToPlay: Verse? = nil){
        let mpic = MPNowPlayingInfoCenter.default()
        var dic = [String: AnyObject]()
        dic[MPMediaItemPropertyTitle] = kApplicationDisplayName as AnyObject
        dic[MPMediaItemPropertyArtist] = "\(dollar.currentChapter.name) - \(dollar.currentReciter.name)" as AnyObject
        if #available(iOS 10.0, *) {
            if let img = UIImage(named: "launch-screen") {
                dic[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: img.size) { _ in img } as AnyObject
            }
        }
        mpic.nowPlayingInfo = dic

        let verse: Verse
        if let verseToPlay = verseToPlay {
            verse = verseToPlay
            self.currentVerseIndex = dollar.currentChapter.verses.index(of: verse) ?? 0
        } else {
            self.currentVerseIndex = isABRepeatActive ? abRepeatStartIndex : 0
            verse = dollar.currentChapter.verses[self.currentVerseIndex]
        }

        // Reset A-B phase when starting fresh
        if verseToPlay == nil {
            refreshABRepeatState()
        }

        delegate?.scrollToVerse(self.currentVerseIndex, searchText: "")

        let audioChapter: AudioChapter = dollar.currentReciter.audioChapters[dollar.currentChapter.id]
        let path: String = audioChapter.verseAudioPath(verse)
        let url: URL = URL(fileURLWithPath: path, isDirectory: false)

        self.isPaused = false
        var error: NSError?
        do {
            self.player = try AVAudioPlayer(contentsOf: url)
        } catch let e as NSError {
            error = e
        }
        self.player?.enableRate = true
        setDefaultRate()
        self.player?.prepareToPlay()
        self.player?.delegate = self
        self.player?.numberOfLoops = isABRepeatActive ? 0 : self.repeats.verseCount

        if error == nil {
            self.player?.play()
            self.isPaused = false
        }
    }
    
    //rest the player
    fileprivate func resetPlayer() {
        self.player?.stop()
        self.player?.delegate = nil
        //self.player = nil
        self.isPaused = false
    }

    @objc func resetABRepeat() {
        abPhase = .introNewVerse
        abPhaseNewVerseIndex = abRepeatStartIndex
        abSequenceRepeatCount = 0
        if isABRepeatActive {
            currentVerseIndex = abRepeatStartIndex
        }
    }
    
    // MARK: AVAudioPlayerDelegate

    /// Rebuild A-B repeat bounds from the stored markers and reset phase state.
    @objc func setupABRepeatPlayer() {
        var foundStart = false
        var startIdx = -1
        var endIdx = -1

        for (arrayIndex, verse) in dollar.currentChapter.verses.enumerated() {
            guard ABRepeatService.sharedInstance().has(verse) else { continue }
            if !foundStart {
                foundStart = true
                startIdx = arrayIndex
            } else {
                endIdx = arrayIndex
                break
            }
        }

        if startIdx >= 0 && endIdx > startIdx {
            abRepeatStartIndex = startIdx
            abRepeatEndIndex = endIdx
            isABRepeatActive = true
        } else if startIdx >= 0 {
            // Only start marker set — treat start as single-verse A-B
            abRepeatStartIndex = startIdx
            abRepeatEndIndex = startIdx
            isABRepeatActive = true
        } else {
            abRepeatStartIndex = -1
            abRepeatEndIndex = -1
            isABRepeatActive = false
        }
        refreshABRepeatState()
    }

    /// Resets the A-B phase tracking to the beginning of the sequence.
    private func refreshABRepeatState() {
        abPhase = .introNewVerse
        abPhaseNewVerseIndex = isABRepeatActive ? abRepeatStartIndex : 0
        abSequenceRepeatCount = 0
        if isABRepeatActive {
            currentVerseIndex = abRepeatStartIndex
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let verses = dollar.currentChapter.verses
        let total = verses.count

        if isABRepeatActive && abRepeatStartIndex >= 0 && abRepeatEndIndex >= abRepeatStartIndex {
            handleABRepeatFinished(verses: verses)
        } else {
            handleNormalPlaybackFinished(verses: verses, total: total)
        }
    }

    // MARK: - A-B Repeat Logic
    //
    // Incremental memorisation algorithm:
    //   Phase 1  – play verse A alone
    //   Phase 2  – play verse A+1 alone, then play the sequence A…A+1
    //   Phase 3  – play verse A+2 alone, then play the sequence A…A+2
    //   …repeat until phase end reaches B, then loop per chapterCount.
    //
    private func handleABRepeatFinished(verses: [Verse]) {
        switch abPhase {
        case .introNewVerse:
            // Finished introducing the new single verse.
            if abPhaseNewVerseIndex == abRepeatStartIndex {
                // Only one verse so far — go straight to advancing the phase.
                advanceABPhase(verses: verses)
            } else {
                // Switch to playing the accumulated sequence from start.
                abPhase = .playSequence
                currentVerseIndex = abRepeatStartIndex
                playCurrentVerse(verses)
            }

        case .playSequence:
            let nextIndex = currentVerseIndex + 1
            if nextIndex <= abPhaseNewVerseIndex {
                // Continue playing the next verse in the sequence.
                currentVerseIndex = nextIndex
                playCurrentVerse(verses)
            } else {
                // Reached the end of this sequence run.
                abSequenceRepeatCount += 1
                let targetRepeats = max(1, sequenceRepeatCountFromSettings())
                if abSequenceRepeatCount < targetRepeats {
                    // Repeat the sequence from start.
                    currentVerseIndex = abRepeatStartIndex
                    playCurrentVerse(verses)
                } else {
                    advanceABPhase(verses: verses)
                }
            }
        }
    }

    /// Move to the next verse phase, or complete the A-B cycle.
    private func advanceABPhase(verses: [Verse]) {
        abSequenceRepeatCount = 0
        if abPhaseNewVerseIndex < abRepeatEndIndex {
            // Introduce the next new verse.
            abPhaseNewVerseIndex += 1
            abPhase = .introNewVerse
            currentVerseIndex = abPhaseNewVerseIndex
            playCurrentVerse(verses)
        } else {
            // Full A-B cycle complete — apply chapter repeat policy.
            handleABCycleComplete(verses: verses)
        }
    }

    private func handleABCycleComplete(verses: [Verse]) {
        switch self.repeats.chapterCount {
        case 0:
            // Play chapter by chapter
            delegate?.playNextChapter()
        case 1:
            // Play once — stop here.
            refreshABRepeatState()
            delegate?.scrollToVerse(abRepeatStartIndex, searchText: "")
        default:
            // Keep repeating — restart from the beginning of the A-B sequence.
            refreshABRepeatState()
            currentVerseIndex = abRepeatStartIndex
            playCurrentVerse(verses)
        }
    }

    private func playCurrentVerse(_ verses: [Verse]) {
        guard currentVerseIndex >= 0 && currentVerseIndex < verses.count else { return }
        delegate?.scrollToVerse(currentVerseIndex, searchText: "")
        play(verses[currentVerseIndex])
    }

    /// Number of times the accumulated sequence should play before advancing.
    private func sequenceRepeatCountFromSettings() -> Int {
        let count = self.repeats.chapterCount
        switch count {
        case 0: return 1
        case 1: return 1
        case 2: return 2
        case 3: return 3
        case 4: return 4
        case 5: return 5
        case 6: return 10
        case 7: return 15
        case 8: return 20
        case 9: return 25
        default: return 1
        }
    }

    // MARK: - Normal (non-AB) Playback Logic

    private func handleNormalPlaybackFinished(verses: [Verse], total: Int) {
        if currentVerseIndex < total - 1 {
            currentVerseIndex += 1
            play(verses[currentVerseIndex])
        } else {
            currentVerseIndex = 0
            switch self.repeats.chapterCount {
            case 0:
                delegate?.playNextChapter()
            case 1:
                break  // play once — stop
            default:
                play(verses[0])
            }
        }
    }
    
    // MARK: Utils
    
    // resume playing the current audio
    @objc func resumePlaying() {
        if self.isPaused == true {
            self.player?.play()
            self.isPaused = false
        }
        else{
            play()
        }
    }
    
    // pause playing the current audio
    @objc func pausePlaying() {
        self.isPaused = true
        self.player?.pause()
    }

    @objc func stopPlaying() {
        self.isPaused = true
        self.player?.stop()
    }
    
    // play the next audio if any
    @objc func playNext() {
        let total = dollar.currentChapter.verses.count
        if currentVerseIndex < total - 1 {
            currentVerseIndex = currentVerseIndex + 1
            refreshABRepeatState()
            play(dollar.currentChapter.verses[currentVerseIndex])
            self.isPaused = false
        }
    }
    
    // play the previous audio if any
    @objc func playPrevious() {
        if currentVerseIndex > 0 {
            currentVerseIndex = currentVerseIndex - 1
            refreshABRepeatState()
            play(dollar.currentChapter.verses[currentVerseIndex])
            self.isPaused = false
        }
    }
    
    // update the current played audio with the corrent numberOfLoops
    @objc func repeatPlay() {
        //Case: "Keep playing verse"
        if repeats.verseCount == repeats.verses.count - 2 {
            repeats.verseCount = -1
        }
        //other cases
        else{
            repeats.verseCount = repeats.verseCount + 1
        }
        
        //set the number of loops
        self.player?.numberOfLoops = repeats.verseCount
        
        //save the repeat value of the disk
        dollar.setPersistentObjectForKey(repeats.verseCount as AnyObject, key: kCurrentRepeatVerseKey)
        NotificationCenter.default.post(name: Notification.Name(rawValue: kRepatCountChangedNotification), object: nil,  userInfo: nil)
    }

    // update the current played audio with the corrent numberOfLoops
    @objc func speedPlay() {
        //Case: "Keep playing verse"
        if repeats.speedCount >= 4 {
            repeats.speedCount = 0
            self.player?.rate = 0.5
        } //other cases
        else{
            repeats.speedCount = repeats.speedCount + 1
            if(repeats.speedCount == 1) {
                self.player?.rate = 0.75
            } else if(repeats.speedCount == 2) {
                self.player?.rate = 1.0
            } else if(repeats.speedCount == 3) {
                self.player?.rate = 1.5
            } else if(repeats.speedCount == 4) {
                self.player?.rate = 2.0
            }
        }

        //save the repeat value of the disk
        dollar.setPersistentObjectForKey(repeats.speedCount as AnyObject, key: kCurrentSpeedVerseKey)
        NotificationCenter.default.post(name: Notification.Name(rawValue: kSpeedCountChangeNotification), object: nil,  userInfo: nil)
    }

    // update the current played audio with the corrent numberOfLoops
    @objc func setDefaultRate() {
        if(repeats.speedCount == 0) {
            self.player?.rate = 0.5
        } else if(repeats.speedCount == 1) {
            self.player?.rate = 0.75
        } else if(repeats.speedCount == 2) {
            self.player?.rate = 1.0
        } else if(repeats.speedCount == 3) {
            self.player?.rate = 1.5
        } else if(repeats.speedCount == 4) {
            self.player?.rate = 2.0
        }
    }

    // stops and resets the player
    @objc func stopAndReset() {
        resetPlayer()
    }
    
    // check whether the audio is played or not
    @objc func isPlaying() -> Bool{
        return self.player != nil && self.player!.isPlaying
    }
    
    // get the icon name of the repeat control
    @objc func repeatIconName() -> String {
        if repeats.verseCount == -1 {
            return "repeat-∞"
        }
        else{
            return "repeat-\(repeats.verseCount + 1)"
        }
    }

    @objc func speedIconName() -> String {
        if repeats.speedCount == 0 {
            return "half"
        } else if repeats.speedCount == 1 {
            return "threeforth"
        } else if repeats.speedCount == 3 {
            return "oneandhalf"
        } else if repeats.speedCount == 4 {
            return "double"
        } else{
            return "normal"
        }
    }

    deinit {
        self.player?.delegate = nil
        self.player = nil
    }
}

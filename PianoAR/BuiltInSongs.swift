import Foundation

/// Built-in library: recognizable public-domain pieces arranged with CHORDS —
/// left-hand harmony under a right-hand melody (notes sharing a startBeat form
/// a chord group; SongPlayer waits until every note of the group is played).
/// Defined directly in Swift so they're always available without depending on
/// bundled resource files.
enum BuiltInSongs {

    static let all: [Song] = [
        canonInD,
        furElise,
        moonlightSonata,
        preludeInC,
        greensleeves,
        houseRisingSun,
        mountainKing,
        amazingGrace,
        scarboroughFair,
        turkishMarch,
    ]

    /// Default song on launch.
    static var first: Song { all[0] }

    // MARK: - Builder

    private static func song(_ title: String, bpm: Double,
                             _ raw: [(String, Double, Double, String)]) -> Song {
        Song(title: title, bpm: bpm,
             notes: raw.map { SongNote(key: $0.0, startBeat: $0.1,
                                       durationBeats: $0.2, hand: $0.3) })
    }
    private static let R = "right", L = "left"

    // MARK: - Songs

    /// Pachelbel — the most famous chord progression there is.
    /// LH two-note chords (root+fifth), RH the descending violin line.
    private static let canonInD = song("Canon in D", bpm: 70, [
        // Pass 1 — half-note melody over the chords
        ("D3",0,2,L),("A3",0,2,L),   ("F#4",0,2,R),
        ("A2",2,2,L),("E3",2,2,L),   ("E4",2,2,R),
        ("B2",4,2,L),("F#3",4,2,L),  ("D4",4,2,R),
        ("F#2",6,2,L),("C#3",6,2,L), ("C#4",6,2,R),
        ("G2",8,2,L),("D3",8,2,L),   ("B3",8,2,R),
        ("D3",10,2,L),("A3",10,2,L), ("A3",10,2,R),
        ("G2",12,2,L),("D3",12,2,L), ("B3",12,2,R),
        ("A2",14,2,L),("E3",14,2,L), ("C#4",14,2,R),
        // Pass 2 — quarter-note movement
        ("D3",16,2,L),("A3",16,2,L), ("F#4",16,1,R),("A4",17,1,R),
        ("A2",18,2,L),("E3",18,2,L), ("E4",18,1,R),("G4",19,1,R),
        ("B2",20,2,L),("F#3",20,2,L),("D4",20,1,R),("F#4",21,1,R),
        ("F#2",22,2,L),("C#3",22,2,L),("C#4",22,1,R),("E4",23,1,R),
        ("G2",24,2,L),("D3",24,2,L), ("B3",24,1,R),("D4",25,1,R),
        ("D3",26,2,L),("A3",26,2,L), ("A3",26,1,R),("C#4",27,1,R),
        ("G2",28,2,L),("D3",28,2,L), ("B3",28,1,R),("D4",29,1,R),
        ("A2",30,2,L),("E3",30,2,L), ("C#4",30,1,R),("D4",31,1,R),
        ("D3",32,4,L),("A3",32,4,L),("F#4",32,4,R),
    ])

    /// Beethoven — the A section with the broken-chord left hand.
    private static let furElise = song("Für Elise", bpm: 72, [
        ("E5",0,0.5,R),("D#5",0.5,0.5,R),("E5",1,0.5,R),("D#5",1.5,0.5,R),
        ("E5",2,0.5,R),("B4",2.5,0.5,R),("D5",3,0.5,R),("C5",3.5,0.5,R),
        ("A4",4,1,R),
        ("A2",4,0.5,L),("E3",4.5,0.5,L),("A3",5,0.5,L),
        ("C4",5.5,0.5,R),("E4",6,0.5,R),("A4",6.5,0.5,R),
        ("B4",7,1,R),
        ("E2",7,0.5,L),("E3",7.5,0.5,L),("G#3",8,0.5,L),
        ("E4",8.5,0.5,R),("G#4",9,0.5,R),("B4",9.5,0.5,R),
        ("C5",10,1,R),
        ("A2",10,0.5,L),("E3",10.5,0.5,L),("A3",11,0.5,L),
        ("E4",11.5,0.5,R),
        ("E5",12,0.5,R),("D#5",12.5,0.5,R),("E5",13,0.5,R),("D#5",13.5,0.5,R),
        ("E5",14,0.5,R),("B4",14.5,0.5,R),("D5",15,0.5,R),("C5",15.5,0.5,R),
        ("A4",16,1,R),
        ("A2",16,0.5,L),("E3",16.5,0.5,L),("A3",17,0.5,L),
        ("C4",17.5,0.5,R),("E4",18,0.5,R),("A4",18.5,0.5,R),
        ("B4",19,1,R),
        ("E2",19,0.5,L),("E3",19.5,0.5,L),("G#3",20,0.5,L),
        ("E4",20.5,0.5,R),("C5",21,0.5,R),("B4",21.5,0.5,R),
        ("A4",22,2,R),
        ("A2",22,2,L),("E3",22,2,L),
    ])

    /// Beethoven — the opening arpeggios over deep octave bass.
    private static let moonlightSonata = song("Moonlight Sonata", bpm: 58, [
        ("C#2",0,4,L),("C#3",0,4,L),
        ("G#3",0,1,R),("C#4",1,1,R),("E4",2,1,R),("G#3",3,1,R),
        ("B1",4,4,L),("B2",4,4,L),
        ("G#3",4,1,R),("C#4",5,1,R),("E4",6,1,R),("G#3",7,1,R),
        ("A1",8,4,L),("A2",8,4,L),
        ("A3",8,1,R),("C#4",9,1,R),("E4",10,1,R),("A3",11,1,R),
        ("F#1",12,4,L),("F#2",12,4,L),
        ("A3",12,1,R),("D4",13,1,R),("F#4",14,1,R),("A3",15,1,R),
        ("G#1",16,4,L),("G#2",16,4,L),
        ("G#3",16,1,R),("C4",17,1,R),("D#4",18,1,R),("G#3",19,1,R),
        ("C#2",20,4,L),("C#3",20,4,L),
        ("G#3",20,1,R),("C#4",21,1,R),("E4",22,2,R),
    ])

    /// Bach — the arpeggiated chord study everyone knows.
    private static let preludeInC = song("Prelude in C  (Bach)", bpm: 66, [
        ("C3",0,4,L),
        ("E4",0,0.5,R),("G4",0.5,0.5,R),("C5",1,0.5,R),("E5",1.5,0.5,R),
        ("G4",2,0.5,R),("C5",2.5,0.5,R),("E5",3,0.5,R),("G5",3.5,0.5,R),
        ("D3",4,4,L),
        ("F4",4,0.5,R),("A4",4.5,0.5,R),("D5",5,0.5,R),("F5",5.5,0.5,R),
        ("A4",6,0.5,R),("D5",6.5,0.5,R),("F5",7,0.5,R),("A5",7.5,0.5,R),
        ("G2",8,4,L),
        ("F4",8,0.5,R),("G4",8.5,0.5,R),("B4",9,0.5,R),("F5",9.5,0.5,R),
        ("G4",10,0.5,R),("B4",10.5,0.5,R),("F5",11,0.5,R),("G5",11.5,0.5,R),
        ("C3",12,4,L),
        ("E4",12,0.5,R),("G4",12.5,0.5,R),("C5",13,0.5,R),("E5",13.5,0.5,R),
        ("G4",14,0.5,R),("C5",14.5,0.5,R),("E5",15,1,R),
    ])

    /// Traditional — melody over Am/C/G chords.
    private static let greensleeves = song("Greensleeves", bpm: 100, [
        ("A4",0,1,R),
        ("A2",1,3,L),("E3",1,3,L),   ("C5",1,2,R),("D5",3,1,R),
        ("C3",4,3,L),("G3",4,3,L),   ("E5",4,1.5,R),("F5",5.5,0.5,R),("E5",6,1,R),
        ("G2",7,3,L),("D3",7,3,L),   ("D5",7,2,R),("B4",9,1,R),
        ("E2",10,3,L),("B2",10,3,L), ("G4",10,1.5,R),("A4",11.5,0.5,R),("B4",12,1,R),
        ("A2",13,3,L),("E3",13,3,L), ("C5",13,2,R),("A4",15,1,R),
        ("A2",16,3,L),("E3",16,3,L), ("A4",16,1.5,R),("G#4",17.5,0.5,R),("A4",18,1,R),
        ("E2",19,3,L),("B2",19,3,L), ("B4",19,2,R),("G#4",21,1,R),
        ("A2",22,3,L),("E3",22,3,L), ("A4",22,3,R),
    ])

    /// Traditional — the classic arpeggio-picked chord cycle.
    private static let houseRisingSun = song("House of the Rising Sun", bpm: 120, [
        ("A2",0,6,L),
        ("A3",0,1,R),("C4",1,1,R),("E4",2,1,R),("A4",3,1,R),("E4",4,1,R),("C4",5,1,R),
        ("C3",6,6,L),
        ("C4",6,1,R),("E4",7,1,R),("G4",8,1,R),("C5",9,1,R),("G4",10,1,R),("E4",11,1,R),
        ("D3",12,6,L),
        ("D4",12,1,R),("F#4",13,1,R),("A4",14,1,R),("D5",15,1,R),("A4",16,1,R),("F#4",17,1,R),
        ("F2",18,6,L),
        ("F3",18,1,R),("A3",19,1,R),("C4",20,1,R),("F4",21,1,R),("C4",22,1,R),("A3",23,1,R),
        ("A2",24,6,L),
        ("A3",24,1,R),("C4",25,1,R),("E4",26,1,R),("A4",27,1,R),("E4",28,1,R),("C4",29,1,R),
        ("E2",30,6,L),
        ("E3",30,1,R),("G#3",31,1,R),("B3",32,1,R),("E4",33,1,R),("B3",34,1,R),("G#3",35,1,R),
    ])

    /// Grieg — the creeping theme, drone fifths underneath.
    private static let mountainKing = song("Hall of the Mountain King", bpm: 112, [
        ("E2",0,4,L),("B2",0,4,L),
        ("E4",0,0.5,R),("F#4",0.5,0.5,R),("G4",1,0.5,R),("A4",1.5,0.5,R),
        ("B4",2,0.5,R),("G4",2.5,0.5,R),("B4",3,1,R),
        ("E2",4,4,L),("B2",4,4,L),
        ("A#4",4,0.5,R),("F#4",4.5,0.5,R),("A#4",5,1,R),
        ("A4",6,0.5,R),("F4",6.5,0.5,R),("A4",7,1,R),
        ("E2",8,4,L),("B2",8,4,L),
        ("E4",8,0.5,R),("F#4",8.5,0.5,R),("G4",9,0.5,R),("A4",9.5,0.5,R),
        ("B4",10,0.5,R),("G4",10.5,0.5,R),("B4",11,0.5,R),("E5",11.5,0.5,R),
        ("E2",12,4,L),("B2",12,4,L),
        ("D5",12,0.5,R),("B4",12.5,0.5,R),("G4",13,0.5,R),("B4",13.5,0.5,R),
        ("D5",14,2,R),
    ])

    /// Traditional — melody with full chord support.
    private static let amazingGrace = song("Amazing Grace", bpm: 84, [
        ("D4",0,1,R),
        ("G2",1,3,L),("D3",1,3,L),("B3",1,3,L),  ("G4",1,2,R),("B4",3,0.5,R),("G4",3.5,0.5,R),
        ("C3",4,3,L),("G3",4,3,L),               ("B4",4,2,R),("A4",6,1,R),
        ("G2",7,3,L),("D3",7,3,L),("B3",7,3,L),  ("G4",7,2,R),("E4",9,1,R),
        ("D3",10,3,L),("A3",10,3,L),             ("D4",10,3,R),
        ("D4",13,1,R),
        ("G2",14,3,L),("D3",14,3,L),("B3",14,3,L),("G4",14,2,R),("B4",16,0.5,R),("G4",16.5,0.5,R),
        ("C3",17,3,L),("G3",17,3,L),             ("B4",17,2,R),("A4",19,1,R),
        ("G2",20,3,L),("D3",20,3,L),             ("D5",20,3,R),
        ("G2",23,3,L),("D3",23,3,L),("B3",23,3,L),("B4",23,3,R),
    ])

    /// Traditional — modal melody over open fifths.
    private static let scarboroughFair = song("Scarborough Fair", bpm: 104, [
        ("D3",0,3,L),("A3",0,3,L),   ("D4",0,1,R),("D4",1,1,R),("A4",2,1,R),
        ("D3",3,3,L),("A3",3,3,L),   ("A4",3,1,R),("E4",4,1.5,R),("F4",5.5,0.5,R),
        ("D3",6,3,L),("A3",6,3,L),   ("E4",6,1,R),("D4",7,2,R),
        ("C3",9,3,L),("G3",9,3,L),   ("A4",9,1,R),("C5",10,1,R),("D5",11,1,R),
        ("C3",12,3,L),("G3",12,3,L), ("C5",12,1,R),("A4",13,1,R),("B4",14,1,R),
        ("D3",15,3,L),("A3",15,3,L), ("A4",15,3,R),
        ("F3",18,3,L),("C4",18,3,L), ("D5",18,1,R),("D5",19,1,R),("D5",20,1,R),
        ("C3",21,3,L),("G3",21,3,L), ("C5",21,1,R),("A4",22,1,R),("G4",23,1,R),
        ("D3",24,3,L),("A3",24,3,L), ("F4",24,1,R),("E4",25,1,R),("D4",26,2,R),
    ])

    /// Mozart — the famous rondo theme with Am chord stabs.
    private static let turkishMarch = song("Turkish March", bpm: 116, [
        ("B4",0,0.5,R),("A4",0.5,0.5,R),("G#4",1,0.5,R),("A4",1.5,0.5,R),
        ("A2",2,1,L),("E3",2,1,L),   ("C5",2,1,R),
        ("D5",3.5,0.5,R),("C5",4,0.5,R),("B4",4.5,0.5,R),("C5",5,0.5,R),
        ("A2",5.5,1,L),("E3",5.5,1,L),("E5",5.5,1,R),
        ("F5",7,0.5,R),("E5",7.5,0.5,R),("D#5",8,0.5,R),("E5",8.5,0.5,R),
        ("B5",9,0.5,R),("A5",9.5,0.5,R),("G#5",10,0.5,R),("A5",10.5,0.5,R),
        ("B5",11,0.5,R),("A5",11.5,0.5,R),("G#5",12,0.5,R),("A5",12.5,0.5,R),
        ("A2",13,2,L),("E3",13,2,L),("C6",13,2,R),
        ("A5",15,1,R),
        ("A2",15,1,L),("C4",15,1,L),
        ("B5",16,1,R),
        ("E3",16,1,L),("B3",16,1,L),
        ("A5",17,1,R),
        ("A2",17,2,L),("A3",17,2,L),
    ])
}

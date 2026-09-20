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
        // Harder, and each one leans on something different — see below.
        minuetInG,
        preludeInCBach,
        entertainer,
        toccataDMinor,
        bumblebee,
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
    /// Beethoven, Op. 27 No. 2 — the one everybody knows, and the saddest
    /// thing in the library. Thirty-six bars: the C# minor opening, the lift
    /// into E major, and the descent back. About three minutes at the written
    /// tempo, and longer if you slow it with TEMPO.
    ///
    /// Hard for the app as well as for the hands: the melody sits on top of a
    /// constant arpeggio, so most beats ask for two notes at once, and the
    /// bass octaves run down to A1 and F#1 — below C3, where the microphone
    /// is least reliable and where the app credits rather than checks.
    private static let moonlightSonata = song("Moonlight Sonata", bpm: 54, [
        ("C#2",0,4,L),("C#3",0,4,L),
        ("G#3",0,1,R),("C#4",1,1,R),("E4",2,1,R),("C#4",3,1,R),
        ("C#2",4,4,L),("C#3",4,4,L),
        ("G#3",4,1,R),("C#4",5,1,R),("E4",6,1,R),("C#4",7,1,R),
        ("A1",8,4,L),("A2",8,4,L),
        ("A3",8,1,R),("C#4",9,1,R),("E4",10,1,R),("C#4",11,1,R),
        ("F#1",12,4,L),("F#2",12,4,L),
        ("A3",12,1,R),("D4",13,1,R),("F#4",14,1,R),("D4",15,1,R),
        ("G#1",16,4,L),("G#2",16,4,L),
        ("G#3",16,1,R),("C4",17,1,R),("D#4",18,1,R),("C4",19,1,R),
        ("G#1",20,4,L),("G#2",20,4,L),
        ("G#3",20,1,R),("C4",21,1,R),("F#4",22,1,R),("C4",23,1,R),
        ("C#2",24,4,L),("C#3",24,4,L),
        ("G#3",24,1,R),("C#4",25,1,R),("E4",26,1,R),("C#4",27,1,R),
        ("G#4",24,2,R),
        ("G#4",26,2,R),
        ("C#2",28,4,L),("C#3",28,4,L),
        ("G#3",28,1,R),("C#4",29,1,R),("E4",30,1,R),("C#4",31,1,R),
        ("G#4",28,2,R),
        ("G#4",30,2,R),
        ("A1",32,4,L),("A2",32,4,L),
        ("A3",32,1,R),("C#4",33,1,R),("E4",34,1,R),("C#4",35,1,R),
        ("A4",32,2,R),
        ("F#1",36,4,L),("F#2",36,4,L),
        ("A3",36,1,R),("D4",37,1,R),("F#4",38,1,R),("D4",39,1,R),
        ("F#4",36,2,R),
        ("G#1",40,4,L),("G#2",40,4,L),
        ("G#3",40,1,R),("C4",41,1,R),("D#4",42,1,R),("C4",43,1,R),
        ("G#4",40,2,R),
        ("G#4",42,2,R),
        ("G#1",44,4,L),("G#2",44,4,L),
        ("G#3",44,1,R),("C4",45,1,R),("F#4",46,1,R),("C4",47,1,R),
        ("G#4",44,2,R),
        ("C#2",48,4,L),("C#3",48,4,L),
        ("G#3",48,1,R),("C#4",49,1,R),("E4",50,1,R),("C#4",51,1,R),
        ("G#4",48,2,R),
        ("G#4",50,2,R),
        ("C#2",52,4,L),("C#3",52,4,L),
        ("G#3",52,1,R),("C#4",53,1,R),("E4",54,1,R),("C#4",55,1,R),
        ("G#4",52,2,R),
        ("G#4",54,2,R),
        ("B1",56,4,L),("B2",56,4,L),
        ("B3",56,1,R),("E4",57,1,R),("G#4",58,1,R),("E4",59,1,R),
        ("B4",56,2,R),
        ("B1",60,4,L),("B2",60,4,L),
        ("B3",60,1,R),("E4",61,1,R),("G#4",62,1,R),("E4",63,1,R),
        ("B4",60,2,R),
        ("B4",62,2,R),
        ("E2",64,4,L),("E3",64,4,L),
        ("B3",64,1,R),("E4",65,1,R),("G#4",66,1,R),("E4",67,1,R),
        ("E5",64,2,R),
        ("E2",68,4,L),("E3",68,4,L),
        ("B3",68,1,R),("E4",69,1,R),("G#4",70,1,R),("E4",71,1,R),
        ("E5",68,2,R),
        ("D#5",70,2,R),
        ("A1",72,4,L),("A2",72,4,L),
        ("A3",72,1,R),("C#4",73,1,R),("E4",74,1,R),("C#4",75,1,R),
        ("E5",72,2,R),
        ("A1",76,4,L),("A2",76,4,L),
        ("A3",76,1,R),("C#4",77,1,R),("E4",78,1,R),("C#4",79,1,R),
        ("E5",76,2,R),
        ("C#5",78,2,R),
        ("D2",80,4,L),("D3",80,4,L),
        ("A3",80,1,R),("D4",81,1,R),("F#4",82,1,R),("D4",83,1,R),
        ("D5",80,2,R),
        ("G#1",84,4,L),("G#2",84,4,L),
        ("G#3",84,1,R),("B3",85,1,R),("D#4",86,1,R),("B3",87,1,R),
        ("B4",84,2,R),
        ("C#2",88,4,L),("C#3",88,4,L),
        ("G#3",88,1,R),("C#4",89,1,R),("E4",90,1,R),("C#4",91,1,R),
        ("C#5",88,2,R),
        ("C#2",92,4,L),("C#3",92,4,L),
        ("G#3",92,1,R),("C#4",93,1,R),("E4",94,1,R),("C#4",95,1,R),
        ("C#5",92,2,R),
        ("B4",94,2,R),
        ("F#1",96,4,L),("F#2",96,4,L),
        ("A3",96,1,R),("D4",97,1,R),("F#4",98,1,R),("D4",99,1,R),
        ("A4",96,2,R),
        ("F#1",100,4,L),("F#2",100,4,L),
        ("A3",100,1,R),("C#4",101,1,R),("F#4",102,1,R),("C#4",103,1,R),
        ("A4",100,2,R),
        ("G#4",102,2,R),
        ("G#1",104,4,L),("G#2",104,4,L),
        ("G#3",104,1,R),("C4",105,1,R),("D#4",106,1,R),("C4",107,1,R),
        ("G#4",104,2,R),
        ("G#1",108,4,L),("G#2",108,4,L),
        ("G#3",108,1,R),("C4",109,1,R),("F#4",110,1,R),("C4",111,1,R),
        ("F#4",108,2,R),
        ("D#4",110,2,R),
        ("C#2",112,4,L),("C#3",112,4,L),
        ("G#3",112,1,R),("C#4",113,1,R),("E4",114,1,R),("C#4",115,1,R),
        ("C#4",112,2,R),
        ("C#2",116,4,L),("C#3",116,4,L),
        ("G#3",116,1,R),("C#4",117,1,R),("E4",118,1,R),("C#4",119,1,R),
        ("A1",120,4,L),("A2",120,4,L),
        ("A3",120,1,R),("C#4",121,1,R),("E4",122,1,R),("C#4",123,1,R),
        ("A4",120,2,R),
        ("F#1",124,4,L),("F#2",124,4,L),
        ("A3",124,1,R),("D4",125,1,R),("F#4",126,1,R),("D4",127,1,R),
        ("F#4",124,2,R),
        ("G#1",128,4,L),("G#2",128,4,L),
        ("G#3",128,1,R),("C4",129,1,R),("D#4",130,1,R),("C4",131,1,R),
        ("G#4",128,2,R),
        ("C#2",132,4,L),("C#3",132,4,L),
        ("G#3",132,1,R),("C#4",133,1,R),("E4",134,1,R),("C#4",135,1,R),
        ("C#5",132,2,R),
        ("C#2",136,4,L),("C#3",136,4,L),
        ("G#3",136,1,R),("C#4",137,1,R),("E4",138,1,R),("C#4",139,1,R),
        ("C#5",136,2,R),
        ("C#2",140,4,L),("C#3",140,4,L),
        ("G#3",140,1,R),("C#4",141,1,R),("E4",142,1,R),("C#4",143,1,R),
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

    // MARK: - Harder pieces
    //
    // Chosen so each one stresses a different part of the detector, which is
    // measured now rather than guessed: the microphone hears C3-B5 best
    // (83-100 % of notes land in the top three), the bottom two octaves
    // worst, and fast passages sit around 77 %.

    /// Bach (Petzold) — steady, almost entirely inside the register the
    /// microphone hears best. If anything ever fails here, the problem is not
    /// the piano range.
    private static let minuetInG = song("Minuet in G — Bach", bpm: 120, [
        ("D5",0,1,R),("G4",1,0.5,R),("A4",1.5,0.5,R),("B4",2,0.5,R),("C5",2.5,0.5,R),
        ("G2",0,3,L),("B3",0,3,L),
        ("D5",3,1,R),("G4",4,1,R),("G4",5,1,R),
        ("G2",3,3,L),("B3",3,3,L),
        ("E5",6,1,R),("C5",7,0.5,R),("D5",7.5,0.5,R),("E5",8,0.5,R),("F#5",8.5,0.5,R),
        ("C3",6,3,L),("E3",6,3,L),
        ("G5",9,1,R),("G4",10,1,R),("G4",11,1,R),
        ("G2",9,3,L),("B3",9,3,L),
        ("C5",12,1,R),("D5",13,0.5,R),("C5",13.5,0.5,R),("B4",14,0.5,R),("A4",14.5,0.5,R),
        ("A2",12,3,L),("C3",12,3,L),
        ("B4",15,1,R),("C5",16,0.5,R),("B4",16.5,0.5,R),("A4",17,0.5,R),("G4",17.5,0.5,R),
        ("G2",15,3,L),("B3",15,3,L),
        ("F#4",18,1,R),("G4",19,0.5,R),("A4",19.5,0.5,R),("B4",20,0.5,R),("G4",20.5,0.5,R),
        ("D3",18,3,L),("F#3",18,3,L),
        ("A4",21,2,R),("G4",23,1,R),
        ("G2",21,3,L),("B3",21,3,L),
    ])

    /// Bach, Well-Tempered Clavier — the arpeggio everyone knows. A steady
    /// stream of single notes spanning three octaves, so it exercises the
    /// register boundaries without ever playing two notes at once.
    private static let preludeInCBach = song("Prelude in C — Bach", bpm: 76, [
        ("C3",0,0.5,L),("E3",0.5,0.5,L),
        ("G4",1,0.5,R),("C5",1.5,0.5,R),("E5",2,0.5,R),
        ("G4",2.5,0.5,R),("C5",3,0.5,R),("E5",3.5,0.5,R),
        ("C3",4,0.5,L),("D3",4.5,0.5,L),
        ("A4",5,0.5,R),("D5",5.5,0.5,R),("F5",6,0.5,R),
        ("A4",6.5,0.5,R),("D5",7,0.5,R),("F5",7.5,0.5,R),
        ("B2",8,0.5,L),("D3",8.5,0.5,L),
        ("G4",9,0.5,R),("D5",9.5,0.5,R),("F5",10,0.5,R),
        ("G4",10.5,0.5,R),("D5",11,0.5,R),("F5",11.5,0.5,R),
        ("C3",12,0.5,L),("E3",12.5,0.5,L),
        ("G4",13,0.5,R),("C5",13.5,0.5,R),("E5",14,0.5,R),
        ("G4",14.5,0.5,R),("C5",15,0.5,R),("E5",15.5,0.5,R),
        ("C3",16,0.5,L),("E3",16.5,0.5,L),
        ("A4",17,0.5,R),("E5",17.5,0.5,R),("A5",18,0.5,R),
        ("A4",18.5,0.5,R),("E5",19,0.5,R),("A5",19.5,0.5,R),
        ("C3",20,0.5,L),("D3",20.5,0.5,L),
        ("F#4",21,0.5,R),("A4",21.5,0.5,R),("D5",22,0.5,R),
        ("F#4",22.5,0.5,R),("A4",23,0.5,R),("D5",23.5,0.5,R),
    ])

    /// Joplin — syncopation. The melody lands off the beat almost throughout,
    /// which is the real test of whether the timing feels right rather than
    /// merely whether the notes are found.
    private static let entertainer = song("The Entertainer — Joplin", bpm: 80, [
        ("D5",0,0.5,R),("D#5",0.5,0.5,R),("E5",1,0.5,R),
        ("C6",1.5,0.5,R),("E5",2,0.5,R),("C6",2.5,0.5,R),("E5",3,0.5,R),
        ("C6",3.5,1.5,R),
        ("C3",1.5,1,L),("G3",1.5,1,L),
        ("C5",5,0.5,R),("D5",5.5,0.5,R),("D#5",6,0.5,R),("E5",6.5,0.5,R),
        ("C5",7,0.5,R),("D5",7.5,0.5,R),
        ("E5",8,1.5,R),
        ("C3",5,1,L),("G3",5,1,L),
        ("B4",9.5,0.5,R),("D5",10,0.5,R),
        ("C5",10.5,1.5,R),
        ("G2",9.5,1,L),("D3",9.5,1,L),
        ("D5",13,0.5,R),("D#5",13.5,0.5,R),("E5",14,0.5,R),
        ("C6",14.5,0.5,R),("E5",15,0.5,R),("C6",15.5,0.5,R),("E5",16,0.5,R),
        ("C6",16.5,1.5,R),
        ("C3",14.5,1,L),("G3",14.5,1,L),
        ("C5",18,0.5,R),("D5",18.5,0.5,R),("D#5",19,0.5,R),("E5",19.5,0.5,R),
        ("C6",20,0.5,R),("C6",20.5,0.5,R),("A5",21,1,R),
        ("C3",18,1,L),("G3",18,1,L),
    ])

    /// Bach — the most famous opening in organ music, in unison octaves.
    /// It runs down into the left hand deliberately: this is the piece to
    /// play when you want to see where the microphone starts to struggle.
    private static let toccataDMinor = song("Toccata in D minor — Bach", bpm: 66, [
        ("A5",0,0.5,R),("G5",0.5,0.25,R),("A5",0.75,1.25,R),
        ("A4",0,0.5,L),("G4",0.5,0.25,L),("A4",0.75,1.25,L),
        ("G5",2.5,0.25,R),("F5",2.75,0.25,R),("E5",3,0.25,R),("D5",3.25,0.25,R),
        ("C#5",3.5,0.5,R),("D5",4,1.5,R),
        ("G4",2.5,0.25,L),("F4",2.75,0.25,L),("E4",3,0.25,L),("D4",3.25,0.25,L),
        ("C#4",3.5,0.5,L),("D4",4,1.5,L),
        ("A4",6,0.5,R),("G4",6.5,0.25,R),("A4",6.75,1.25,R),
        ("A3",6,0.5,L),("G3",6.5,0.25,L),("A3",6.75,1.25,L),
        ("E4",8.5,0.25,R),("F4",8.75,0.25,R),("C#4",9,0.5,R),("D4",9.5,1.5,R),
        ("E3",8.5,0.25,L),("F3",8.75,0.25,L),("C#3",9,0.5,L),("D3",9.5,1.5,L),
    ])

    /// Rimsky-Korsakov — a chromatic run with no gaps at all. This is the
    /// speed limit made audible: measured, fast passages land around 77 %
    /// against 85 % for slow ones, so expect this to be the piece that
    /// stumbles first. Written at half speed; wind it up with TEMPO.
    private static let bumblebee = song("Flight of the Bumblebee", bpm: 60, [
        ("E5",0,0.25,R),("D#5",0.25,0.25,R),("D5",0.5,0.25,R),("C#5",0.75,0.25,R),
        ("C5",1,0.25,R),("B4",1.25,0.25,R),("A#4",1.5,0.25,R),("A4",1.75,0.25,R),
        ("G#4",2,0.25,R),("G4",2.25,0.25,R),("F#4",2.5,0.25,R),("F4",2.75,0.25,R),
        ("E4",3,0.25,R),("D#4",3.25,0.25,R),("D4",3.5,0.25,R),("C#4",3.75,0.25,R),
        ("C4",4,0.5,R),("E3",4,1,L),
        ("C4",5,0.25,R),("C#4",5.25,0.25,R),("D4",5.5,0.25,R),("D#4",5.75,0.25,R),
        ("E4",6,0.25,R),("F4",6.25,0.25,R),("F#4",6.5,0.25,R),("G4",6.75,0.25,R),
        ("G#4",7,0.25,R),("A4",7.25,0.25,R),("A#4",7.5,0.25,R),("B4",7.75,0.25,R),
        ("C5",8,0.5,R),("A3",8,1,L),
        ("B4",9,0.25,R),("A#4",9.25,0.25,R),("A4",9.5,0.25,R),("G#4",9.75,0.25,R),
        ("G4",10,0.25,R),("F#4",10.25,0.25,R),("F4",10.5,0.25,R),("E4",10.75,0.25,R),
        ("D#4",11,0.5,R),("E4",11.5,1,R),("E3",11,1.5,L),
    ])
}

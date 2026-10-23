#!/usr/bin/env python3
"""Axe FX Preset Organizer — Automatically sorts presets into Option 1 hierarchy:
   Artists/<Artist>/<Album>/<Song>.json
   Genre/<Genre>/<Preset>.json
"""
import argparse
import json
import os
import re
import shutil
import sys
from pathlib import Path

# Popular music knowledge base for instant offline matching
KNOWN_CATALOG = {
    "bullet for my valentine": {
        "artist": "Bullet For My Valentine",
        "genre": "Metalcore",
        "albums": {
            "the poison": ["room 409", "tears don't fall", "all these things i hate", "4 words (to choke upon)", "her voice resides", "suffocating under words of sorrow", "hit the floor"],
            "scream aim fire": ["scream aim fire", "waking the demon", "hearts burst into fire"],
            "fever": ["your betrayal", "the last fight"]
        }
    },
    "disturbed": {
        "artist": "Disturbed",
        "genre": "Nu Metal",
        "albums": {
            "the sickness": ["down with the sickness", "stupify", "voices", "the game"],
            "ten thousand fists": ["stricken", "ten thousand fists", "guarded", "deify"],
            "indestructible": ["indestructible", "inside the fire"]
        }
    },
    "feared": {
        "artist": "Feared",
        "genre": "Death Metal",
        "albums": {
            "furor incarnatus": ["lords resistance army", "furor incarnatus"]
        }
    },
    "korn": {
        "artist": "Korn",
        "genre": "Nu Metal",
        "albums": {
            "follow the leader": ["freak on a leash", "got the life", "dead bodies everywhere", "it's on!"],
            "korn": ["blind", "clown", "shoots and ladders", "faget"],
            "life is peachy": ["a.d.i.d.a.s.", "twist", "good god", "no place to hide"],
            "issues": ["falling away from me", "somebody someone", "make me bad", "trash"],
            "untouchables": ["here to stay", "thoughtless", "alone i break"]
        }
    },
    "lamb of god": {
        "artist": "Lamb of God",
        "genre": "Metalcore",
        "albums": {
            "ashes of the wake": ["laid to rest", "omerta", "hourglass", "now you've got something to die for", "ashes of the wake", "the faded line"],
            "as the palaces burn": ["ruin", "11th hour", "purified", "vigil"],
            "sacrament": ["redneck", "walk with me in hell", "blacken the cursed sun", "descending"],
            "wrath": ["set to fail", "contractor", "in your words"],
            "vii: sturm und drang": ["512", "still echoes", "overlord"]
        }
    },
    "limp bizkit": {
        "artist": "Limp Bizkit",
        "genre": "Nu Metal",
        "albums": {
            "significant other": ["break stuff", "nookie", "re-arranged", "i'm broke", "show me what you got"],
            "chocolate starfish and the hot dog flavored water": ["my way", "rollin'", "take a look around", "boiler", "hot dog"],
            "three dollar bill, y'all": ["faith", "counterfeit", "pollution"]
        }
    },
    "mudvayne": {
        "artist": "Mudvayne",
        "genre": "Nu Metal",
        "albums": {
            "l.d. 50": ["dig", "death blooms", "internal primates forever", "severed", "cradle", "-1", "nothing to gein", "under my skin"],
            "the end of all things to come": ["not falling", "silenced", "world so cold"],
            "lost and found": ["happy?", "determined", "fall into sleep", "forget to remember"]
        }
    },
    "rammstein": {
        "artist": "Rammstein",
        "genre": "Industrial Metal",
        "albums": {
            "sehnsucht": ["stripped", "du hast", "engel", "sehnsucht", "bück dich", "tier", "spiel mit mir"],
            "herzeleid": ["rammstein", "du riechst so gut", "asche zu asche", "seemann"],
            "mutter": ["sonne", "ich will", "feuer frei!", "mutter", "links 2 3 4", "mein herz brennt"],
            "reise, reise": ["mein teil", "amerika", "keine lust", "ohne dich"],
            "rammstein": ["deutschland", "radio", "ausländer"]
        }
    },
    "slipknot": {
        "artist": "Slipknot",
        "genre": "Nu Metal",
        "albums": {
            "vol. 3 (the subliminal verses)": ["before i forget", "duality", "vermillion", "the nameless", "pulse of the maggots", "the blister exists", "danger - keep away"],
            "slipknot": ["wait and bleed", "spit it out", "eyeless", "surfacing", "sic", "(sic)", "prosthetics"],
            "iowa": ["people = shit", "disasterpiece", "my plague", "the heretic anthem", "left behind", "everything ends"],
            "all hope is gone": ["psychosocial", "dead memories", "sulfur", "snuff", "all hope is gone"],
            ".5: the gray chapter": ["the devil in i", "custer", "sarcastrophe", "killpop"],
            "we are not your kind": ["unsainted", "solway firth", "birth of the cruel", "nero forte"]
        }
    },
    "john mellencamp": {
        "artist": "John Mellencamp",
        "genre": "Classic Rock",
        "albums": {
            "american fool": ["jack & diane", "hurts so good", "hand to hold on to"]
        }
    },
    "pink floyd": {
        "artist": "Pink Floyd",
        "genre": "Classic Rock",
        "albums": {
            "the wall": ["young lust", "comfortably numb", "another brick in the wall", "hey you", "in the flesh"],
            "the dark side of the moon": ["time", "money", "breathe", "brain damage", "us and them"]
        }
    },
    "metallica": {
        "artist": "Metallica",
        "genre": "Thrash Metal",
        "albums": {
            "master of puppets": ["master of puppets", "battery", "welcome home (sanitarium)", "disposable heroes", "damage, inc."],
            "ride the lightning": ["ride the lightning", "creeping death", "fade to black", "for whom the bell tolls"],
            "kill 'em all": ["seek & destroy", "four horsemen", "whiplash", "hit the lights"],
            "...and justice for all": ["one", "blackened", "...and justice for all", "harvester of sorrow"],
            "metallica (the black album)": ["enter sandman", "sad but true", "the unforgiven", "wherever i may roam", "nothing else matters"]
        }
    },
    "megadeth": {
        "artist": "Megadeth",
        "genre": "Thrash Metal",
        "albums": {
            "rust in peace": ["holy wars... the punishment due", "holy wars", "hangar 18", "tornado of souls"],
            "peace sells... but who's buying?": ["peace sells", "wake up dead"],
            "countdown to extinction": ["symphony of destruction", "sweating bullets", "skin o' my teeth"]
        }
    },
    "pantera": {
        "artist": "Pantera",
        "genre": "Groove Metal",
        "albums": {
            "cowboys from hell": ["cowboys from hell", "cemetery gates", "domination", "psycho holiday"],
            "vulgar display of power": ["walk", "mouth for war", "this love", "fucking hostile", "hollow"],
            "far beyond driven": ["i'm broken", "5 minutes alone", "becoming"]
        }
    },
    "deftones": {
        "artist": "Deftones",
        "genre": "Nu Metal",
        "albums": {
            "white pony": ["change (in the house of flies)", "change", "digital bath", "passenger"],
            "around the fur": ["my own summer (shove it)", "my own summer", "be quiet and drive (far away)", "be quiet and drive"]
        }
    },
    "tool": {
        "artist": "Tool",
        "genre": "Progressive Metal",
        "albums": {
            "lateralus": ["schism", "parabola", "lateralus"],
            "undertow": ["sober", "prison sex"],
            "ænima": ["stinkfist", "ænema", "forty six & 2"],
            "10,000 days": ["vicarious", "jambi", "the pot"]
        }
    }
}

GENRE_KEYWORDS = {
    "metalcore": "Metalcore",
    "nu metal": "Nu Metal",
    "thrash metal": "Thrash Metal",
    "death metal": "Death Metal",
    "groove metal": "Groove Metal",
    "industrial metal": "Industrial Metal",
    "hard rock": "Hard Rock",
    "classic rock": "Classic Rock",
    "sludge metal": "Sludge Metal",
    "progressive metal": "Progressive Metal",
    "djent": "Djent",
    "blues": "Blues"
}


def title_case(text: str) -> str:
    """Format string into clean Title Case."""
    exceptions = {"a", "an", "the", "and", "but", "or", "for", "nor", "on", "at", "to", "from", "by", "of", "in"}
    words = text.split()
    out = []
    for i, w in enumerate(words):
        lw = w.lower()
        if i == 0 or lw not in exceptions:
            out.append(w.capitalize())
        else:
            out.append(lw)
    return " ".join(out)


def match_existing_casing(parent_dir: Path, target_name: str) -> str:
    """If parent_dir has a subdirectory matching target_name case-insensitively, reuse its exact casing."""
    if not parent_dir.exists():
        return target_name
    target_lower = target_name.lower()
    for child in parent_dir.iterdir():
        if child.is_dir() and child.name.lower() == target_lower:
            return child.name
    return target_name


def resolve_preset_destination(stem: str, preset_data: dict, presets_dir: Path) -> str:
    """Determine the Option 1 target relative path for a preset."""
    # 1. Check metadata
    ai = preset_data.get("ai_metadata") or {}
    prompt = (ai.get("prompt") or "").strip()
    preset_name = (preset_data.get("name") or stem).strip()

    search_text = f"{stem} {prompt} {preset_name}".lower()

    # Match against known catalog
    for artist_key, info in KNOWN_CATALOG.items():
        if artist_key in search_text:
            raw_artist = info["artist"]
            artists_root = presets_dir / "Artists"
            artist_name = match_existing_casing(artists_root, raw_artist)
            artist_dir = artists_root / artist_name

            # Search for specific album and song
            for album_key, songs in info.get("albums", {}).items():
                for song_item in songs:
                    if song_item in search_text:
                        raw_album = title_case(album_key)
                        if "l.d. 50" in album_key:
                            raw_album = "L.D. 50"
                        elif "vol. 3" in album_key:
                            raw_album = "Vol. 3 (The Subliminal Verses)"
                        album_name = match_existing_casing(artist_dir, raw_album)

                        song_title = title_case(song_item)
                        # Check if stem had additional detail e.g. "(Metal Sections)" or "Copy"
                        extra = ""
                        m = re.search(r"\(([^)]+)\)", stem)
                        if m:
                            extra = f" ({m.group(1)})"
                        if "copy" in stem.lower() and "copy" not in song_title.lower():
                            extra += " Copy"
                        return f"Artists/{artist_name}/{album_name}/{song_title}{extra}.json"

            # If no song matched but artist matched
            if " - " in stem:
                parts = stem.split(" - ", 1)
                after = parts[1].strip()
                return f"Artists/{artist_name}/{after}.json"
            else:
                return f"Artists/{artist_name}/{stem}.json"

    # Check for general "Artist - Song" pattern
    if " - " in stem:
        parts = stem.split(" - ", 1)
        artist_cand = title_case(parts[0].strip())
        song_cand = title_case(parts[1].strip())
        artists_root = presets_dir / "Artists"
        artist_name = match_existing_casing(artists_root, artist_cand)
        return f"Artists/{artist_name}/{song_cand}.json"

    # Check for genre keyword
    for kw, g_name in GENRE_KEYWORDS.items():
        if kw in search_text:
            return f"Genre/{g_name}/{stem}.json"

    # If generic or unknown, place under Genre/Custom Tones
    return f"Genre/Custom Tones/{stem}.json"


def organize_directory(presets_dir: Path, dry_run: bool = False):
    print(f"Scanning presets directory: {presets_dir}")
    if not presets_dir.exists():
        print(f"Directory {presets_dir} does not exist.")
        return []

    current_preset_file = presets_dir.parent / "current-preset.txt"
    current_preset_name = ""
    if current_preset_file.exists():
        try:
            current_preset_name = current_preset_file.read_text(encoding="utf-8").strip()
        except Exception:
            pass

    moves = []
    # Only scan presets sitting directly at root of presets_dir
    for entry in sorted(presets_dir.iterdir()):
        if not entry.is_file() or entry.name.startswith(".") or entry.suffix.lower() != ".json":
            continue
        if entry.name == "Default Rig.json":
            # Default Rig stays at root!
            continue

        try:
            with open(entry, "r", encoding="utf-8") as f:
                data = json.load(f)
        except Exception as e:
            print(f"Warning: Could not parse {entry.name}: {e}")
            continue

        target_rel = resolve_preset_destination(entry.stem, data, presets_dir)
        target_path = presets_dir / target_rel

        if target_path == entry:
            continue

        moves.append((entry, target_path, target_rel))

    if not moves:
        print("All presets are already organized!")
        return []

    print(f"\nFound {len(moves)} presets to organize into Option 1 hierarchy:\n")
    for src, dst, rel in moves:
        print(f"  • {src.name}  ──▶  {rel}")

    if dry_run:
        print("\n[Dry Run] No files were moved.")
        return moves

    # Execute moves
    updated_current = None
    for src, dst, rel in moves:
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(src), str(dst))
        # Update current-preset.txt if the active preset was moved
        if current_preset_name and (src.stem == current_preset_name or current_preset_name.endswith(src.stem)):
            updated_current = rel[:-5]  # strip .json

    if updated_current:
        try:
            current_preset_file.write_text(updated_current, encoding="utf-8")
            print(f"\nUpdated active preset in current-preset.txt: {updated_current}")
        except Exception as e:
            print(f"Warning: could not update current-preset.txt: {e}")

    print(f"\nSuccessfully organized {len(moves)} presets.")
    return moves


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Auto-organize Axe FX presets into Option 1 hierarchy.")
    parser.add_argument("--dir", default=os.path.expanduser("~/Library/Application Support/Axe FX/Presets"),
                        help="Path to Presets directory")
    parser.add_argument("--dry-run", action="store_true", help="Preview moves without moving files")
    args = parser.parse_args()

    organize_directory(Path(args.dir), dry_run=args.dry_run)

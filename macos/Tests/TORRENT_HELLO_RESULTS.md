# Local torrent “hello” experiment

Ran `python3 Tests/torrent_hello_experiment.py` against an actual aria2 1.37.0 receiving process. Both tracker and seeder were generated test services on loopback. DHT, peer exchange, and local peer discovery were disabled. No public swarm was contacted, and the application's transfer engine was not modified.

| Experiment | Observed result |
|---|---|
| Send the correct original 16,384-byte piece | Received successfully; file matched the torrent's expected piece SHA-1. aria2 exited successfully. |
| Replace its first five bytes with `hello`, keeping the original torrent | The block was sent to the receiver. aria2 logged `Bad piece hash`, left the download incomplete, and marked the test peer bad. |
| Add `comment: hello` outside the torrent's `info` dictionary | The torrent infohash stayed unchanged. The complete `.torrent` bytes changed. This is a local metadata-file experiment, not an observed peer transfer of the comment. |
| Add `comment: hello` inside the `info` dictionary | The infohash changed. |

The expected piece SHA-1 was `19a066e127d112c405269ba8a3353163ef5e9502`. The modified piece SHA-1 was `d200463c5a3d4034683f4ca54a9bcdc52bdab27d`.

The original and top-level-comment infohashes were both `37110a2e8c4ea41bb7ab8d3d2b27cd9b992f2fe6`. Adding the text inside `info` instead produced `e84a97d595c187852be3e69dee5c2f5582013dd7`.

The BitTorrent metadata extension transfers only the info dictionary, so a top-level comment is not automatically distributed through that exchange: [BEP 9](https://www.bittorrent.org/beps/bep_0009.html). Piece hashing and the infohash are specified in [BEP 3](https://www.bittorrent.org/beps/bep_0003.html).

Raw results, tracker-generated torrent files, and aria2 logs are in `.build/torrent-hello-2h783xg_/`. The experiment script retains an independent output folder on each run.

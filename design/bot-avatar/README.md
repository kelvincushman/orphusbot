# Bot face

The animated face each bot has in the OrphusBot app, made with the [Rive CLI](https://rive.app/docs/cli/overview) (no account needed).

![idle, thinking, working, needs you, done](states.png)

States, left to right: 0 idle, 1 thinking, 2 working, 3 needs you, 4 done. The app sets the state machine `Bot`'s number input `state` (docs/DESIGN.md, M7.4).

To change it, edit `gen.py`, then:

```sh
python3 gen.py 0 > scene.rml
rive . --verify && rive . --screenshot --advance=1   # build/bot-avatar.png
rive . --once                                        # build/bot-avatar.riv
cp build/bot-avatar.riv ../../apps/orphusbot_app/assets/
```

Don't use `rive push`: it uploads to a Rive account.

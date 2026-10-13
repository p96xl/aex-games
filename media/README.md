# media

Drop a short screen-recording of the game here as `demo.gif` (the README embeds
`media/demo.gif`). A 5–10 s clip showing the paddle moving with the handpiece and
the NEM port flashing red on a loss is perfect.

Quick phone video → GIF:

```sh
ffmpeg -i demo.mp4 -vf "fps=15,scale=640:-1:flags=lanczos" -loop 0 demo.gif
```

This is an example Ruby project used in Codeanywhere.

[Try it out](https://app.codeanywhere.com/#https://github.com/Codeanywhere-Templates/ruby)

### Running the project

Open the terminal and run:
```sh
cd test-project
ruby hello.rb
```
Or just press the *Run Code* button found in the top right of the editor panel.

### Hand gesture web demo

A simple camera-based hand gesture visualizer is available at:

`test-project/hand-gesture-app/index.html`

To run it locally with a static file server:

```sh
cd test-project/hand-gesture-app
python3 -m http.server 8080
```

Then open `http://localhost:8080` and allow camera access. The app uses MediaPipe Hands to draw a bright hand skeleton, finger/palm connectors, and animated sparkle effects on top of your hand.

### Want to contribute?

Feel free to [open a PR](https://github.com/Codeanywhere-Templates/ruby) with any suggestions for this test project 😃

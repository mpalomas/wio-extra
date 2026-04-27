Hi, I need a plan to introduce a new set of APIs for Display/Monitor in this codebase.
The idea is to have a subset of SDL3 Display API here: https://wiki.libsdl.org/SDL3/CategoryVideo look for "Display".
Today we are on macOS, so you will focus on the API. No implementation yet, but your plan should detail a macOS way to implement the API, in this existing repo, reusing wio APIs if possible
We will start with a subset of a Display API. I absolutely need:
- To have the list of connected displays
- For each display, I need at least:
  - Resolution, or even better a rectangle such as DisplayBounds or Area, so I can have the position + resolution
  - Content Scale/retina, I guess this can be a f64
  - Work area, can be smaller than resolution. Maybe a UsableBounds, or WorkArea.
  - Refresh rate: must be very accurate. If possible API should provide numerator and denumerator, as f64. Worst case, a f64 value.
Note that usually display API have the concept of "modes" and above properties are bound to a mode.
We can assume for now we query and populate ONLY the current mode. There is no update/setter, we only query.
You goal is to come up with a detailed plan with the public API, and a way to implement it for macOS. DO NOT implement yet. 
First, this is a fork, so a big constrain is to minimize changes on existing files, because eventually I will get conficts
Try your best to use new files, minimize changes. If changes to existing files, better be at the bottom.
You API design must be consistent with wio existing apis and naming conventions.
Maybe you can expose publicly some internals, if that then facilitates new code in dedicated new files.
Save the plan as a markdown file.

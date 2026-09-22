.PHONY: build app run cli test clean install pricing demo video

build:            ## Debug build of every target
	swift build

app:              ## Build build/Indicators.app (release)
	scripts/build-app.sh

run: app          ## Build and launch the menu bar app
	open build/Indicators.app

cli:              ## Print the local-log cost report from the terminal
	swift run -c release indicators-cli report

test:             ## Run unit tests (needs Xcode; Command Line Tools alone lack XCTest)
	swift test

install: app      ## Copy the app into /Applications
	rm -rf /Applications/Indicators.app && cp -R build/Indicators.app /Applications/

demo: app         ## Re-record docs/demo.gif and the popover screenshots (needs Pillow + ffmpeg)
	python3 scripts/record-demo.py

video: app        ## Render docs/demo.mp4 (needs Pillow + ffmpeg)
	python3 scripts/record-demo.py --video

pricing:          ## Refresh the bundled pricing table from LiteLLM
	python3 scripts/update-pricing.py

clean:
	rm -rf .build build

help:
	@grep -E '^[a-z]+:.*##' Makefile | sed 's/:.*##/ —/'

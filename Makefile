.PHONY: build package image clean

build:
	tools/build.sh

package:
	tools/package.sh

image:
	tools/image.sh

clean:
	rm -rf build
	rm -f distr/sprinter-net.zip distr/sprinter-net.img

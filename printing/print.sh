#!/bin/bash

set -eu

DEFAULT_IMAGE="PDI-test-image-reduced.jpg"

# option for user to enter an image name
ARG="${1:-${DEFAULT_IMAGE}}"

IMAGES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)/images"

# check for empty string and fall-back to default image
if [ "${ARG}" == "" ]
then
    IMAGE_PATH="${IMAGES_DIR}/${DEFAULT_IMAGE}"
else
    IMAGE_PATH="${IMAGES_DIR}/${ARG}"
fi

# print the file or report failure
if [ -f ${IMAGE_PATH} ]
then
    echo "Printing ${IMAGE_PATH}"

    # TODO
    # lpr "${IMAGE_PATH}" -P HP_ENVY_4500_series_5299D3
else
    echo "ERROR: Cannot find ${IMAGE_PATH}"
    exit 1
fi

#!/bin/bash

set -eu

DEFAULT_IMAGE_NAME="PDI-test-image-reduced.pdf"
DEFAULT_PRINTER="$(lpstat -p | awk '{print $2}')"

# will get overwritten if user provides arg
PRINTER="${DEFAULT_PRINTER}"

IMAGES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)/images"

print_help() {
    echo ""
    echo "Usage:"
    echo "  print.sh -h | --help                         Display this help message"
    echo "  osm_checkout [-i IMAGE_NAME] [-p PRINTER]    Execute print job"
    echo ""
    echo "Options:"
    echo "  -i, --image              image filename to print. defaults to ${DEFAULT_IMAGE_NAME}"
    echo "  -p, -P, --printer        destination printer name. defaults to ${DEFAULT_PRINTER}"
    echo ""
    echo "Example Commands:"
    echo "  - print.sh"
    echo "  - print.sh -i frontier_color57s.jpg -p HP_ENVY_4500_series_5299D3"
    echo ""
}

get_image_path() {
    # check for empty string and fall-back to default image
    if [ "${IMAGE_NAME:-""}" == "" ]
    then
        IMAGE_PATH="${IMAGES_DIR}/${DEFAULT_IMAGE_NAME}"
    else
        IMAGE_PATH="${IMAGES_DIR}/${IMAGE_NAME}"
    fi

    # confirm path exists
    if [ ! -f ${IMAGE_PATH} ]
    then        
        echo "ERROR: Cannot find ${IMAGE_PATH}"
        exit 1
    fi

    echo "${IMAGE_PATH}"
}

print() {
    echo "Executing print..."
    echo "  Image:    ${IMAGE_PATH}"
    echo "  Printer:  ${PRINTER}"
    echo ""

    COMMAND="lp -d ${PRINTER} ${IMAGE_PATH}"
    echo "  ${COMMAND}"
    eval "${COMMAND}"
}

while [[ $# -gt 0 ]]
do
    ARG="${1:-""}"

    case $ARG in
        -h|--help)
            print_help
            exit
            ;;
        -i|--image)
            IMAGE_NAME="${2}"
            shift
            shift
            ;;
        -p|-P|--printer)
            PRINTER="${2}"
            shift
            shift
            ;;
        "")
            break
            ;;
        *)
            echo "Unrecognized argument '${1}'"
            exit 1
    esac
done

IMAGE_PATH="$( get_image_path )"
print
echo ""
echo "Finished."

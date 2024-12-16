#!/bin/bash

DOCKER_IMAGE=$(echo "${ORB_VAL_PLATFORM}" | cut -d '=' -f2)
IMAGE_FILE="/tmp/act-images-${DOCKER_IMAGE}.tar"

if [ -f "${IMAGE_FILE}" ]; then
    echo "Loading Docker image from $IMAGE_FILE..."
    docker load --input "${IMAGE_FILE}"
else
    echo "No cached Docker image found at $IMAGE_FILE. Skipping load."
fi

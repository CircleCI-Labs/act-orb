#!/bin/bash

DOCKER_IMAGE=$(echo "${ORB_VAL_PLATFORM}" | cut -d '=' -f2)
docker save --output "/tmp/act-images.tar" "${DOCKER_IMAGE}"

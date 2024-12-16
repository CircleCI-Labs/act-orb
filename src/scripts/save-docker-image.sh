#!/bin/bash

DOCKER_IMAGE=$(echo "${ORB_VAL_PLATFORM}" | cut -d '=' -f2)
docker save --output "/tmp/act-images-${DOCKER_IMAGE}.tar" "${DOCKER_IMAGE}"

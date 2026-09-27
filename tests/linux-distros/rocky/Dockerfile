# Rocky Linux 9 (the RHEL family, and the oldest Python of the matrix, 3.9),
# plus exactly what the Linux agents need.
FROM rockylinux/rockylinux:9@sha256:8101994123cf3d0a8fee517bee7f39e555c7d92bd2d9eb3303cc988a0eeed00f
RUN dnf install -y procps-ng python3 iproute \
    && dnf clean all

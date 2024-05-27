FROM --platform=amd64 golang:1.22.3 AS builder

COPY . /juicefs
WORKDIR /juicefs

RUN make juicefs

FROM --platform=amd64 debian AS runtime

RUN apt-get update
RUN apt install -y fuse ca-certificates

FROM runtime AS final

COPY --from=builder /juicefs/juicefs /usr/bin/juicefs

ENTRYPOINT ["juicefs"]

FROM elixir:1.9-alpine as build

COPY . .

ENV MIX_ENV=prod

RUN apk add git gcc g++ musl-dev make cmake file-dev &&\
	echo "import Mix.Config" > config/prod.secret.exs &&\
	mix local.hex --force &&\
	mix local.rebar --force &&\
	mix deps.get --only prod &&\
	mkdir release &&\
	mix release --path release

FROM alpine:3.14

ARG BUILD_DATE
ARG VCS_REF

LABEL maintainer="ops@pleroma.social" \
    org.opencontainers.image.title="pleroma" \
    org.opencontainers.image.description="Pleroma for Docker" \
    org.opencontainers.image.authors="ops@pleroma.social" \
    org.opencontainers.image.vendor="pleroma.social" \
    org.opencontainers.image.documentation="https://git.pleroma.social/pleroma/pleroma" \
    org.opencontainers.image.licenses="AGPL-3.0" \
    org.opencontainers.image.url="https://pleroma.social" \
    org.opencontainers.image.revision=$VCS_REF \
    org.opencontainers.image.created=$BUILD_DATE

ARG HOME=/opt/pleroma
ARG DATA=/var/lib/pleroma

RUN echo "http://nl.alpinelinux.org/alpine/latest-stable/community" >> /etc/apk/repositories &&\
	apk update &&\
	apk add exiftool ffmpeg imagemagick libmagic ncurses postgresql-client curl unzip &&\
	adduser --system --shell /bin/false --home ${HOME} pleroma &&\
	mkdir -p ${DATA}/uploads &&\
	mkdir -p ${DATA}/static &&\
	chown -R pleroma ${DATA} &&\
	mkdir -p /etc/pleroma &&\
	chown -R pleroma /etc/pleroma

USER pleroma
 
RUN curl -L https://github.com/Cl0v1s/mangane/releases/latest/download/static.zip > ${DATA}/static.zip &&\
	mkdir -p ${DATA}/static/frontends/soapbox-fe/vendor/ &&\
    unzip ${DATA}/static.zip -d ${DATA}/static/frontends/soapbox-fe/vendor/

COPY --from=build --chown=pleroma:0 /release ${HOME}

COPY ./config/docker.exs /etc/pleroma/config.exs
COPY ./docker-entrypoint.sh ${HOME}

EXPOSE 4000

ENTRYPOINT ["/opt/pleroma/docker-entrypoint.sh"]

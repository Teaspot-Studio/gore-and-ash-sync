FROM haskell:8.0.1

RUN apt-get update
RUN apt-get -y install curl

ADD mkdocs /opt/project/
ADD LICENSE /opt/project/
ADD Setup.hs /opt/project/
ADD README.md /opt/project/
ADD gore-and-ash-sync.cabal /opt/project/
ADD stack.yaml /opt/project/
ADD src /opt/project/src

WORKDIR /opt/project

ENTRYPOINT ["./mkdocs", "gore-and-ash-sync", "1.2.0.1", "NCrashed"]

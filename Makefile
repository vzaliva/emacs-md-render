# Development tasks for mdview.  Requires GNU Emacs 29+ on PATH (or set EMACS).
EMACS ?= emacs
BATCH := $(EMACS) -Q --batch -L . -L test
SRC   := $(wildcard mdview*.el)
TESTS := $(wildcard test/*-test.el)
FILE  ?= test/fixtures/showcase.md
WIDTH ?= 100

.PHONY: all check compile test lint golden render render-faces render-ansi shot commonmark clean

all: check

check: compile test

compile: clean-elc
	$(BATCH) --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile $(SRC)

test:
	$(BATCH) $(foreach t,$(TESTS),-l $(t)) -f ert-run-tests-batch-and-exit

lint:
	$(BATCH) -l checkdoc --eval '(progn (setq checkdoc-arguments-in-order-flag nil) (dolist (f (list $(foreach f,$(SRC),"$(f)"))) (checkdoc-file f)))'

# Regenerate test/golden/*.txt from the fixtures (review the diff before committing).
golden:
	$(BATCH) -l mdview -l scripts/dump.el --eval '(mdview-dev-update-golden)'

# Plain-text dump of a rendering: make render FILE=foo.md WIDTH=80
render:
	$(BATCH) -l mdview -l scripts/dump.el --eval '(mdview-dev-dump "$(FILE)" $(WIDTH) nil)'

# Same, with {face-name} annotations where the face changes.
render-faces:
	$(BATCH) -l mdview -l scripts/dump.el --eval '(mdview-dev-dump "$(FILE)" $(WIDTH) t)'

# ANSI-coloured dump for a terminal (or pipe through scripts/ansi-to-png.sh).
render-ansi:
	$(BATCH) -l mdview -l scripts/dump.el --eval '(mdview-dev-dump-ansi "$(FILE)" $(WIDTH))'

# Text-mode Emacs screenshot via a private tmux server -> /tmp/mdview-shots/
shot:
	scripts/tmux-shot.sh "$(FILE)" $(WIDTH)

# CommonMark spec conformance (downloads spec.json on first run).
commonmark: test/commonmark/spec.json
	$(BATCH) -l mdview -l test/commonmark/run-spec.el -f mdview-commonmark-report

test/commonmark/spec.json:
	mkdir -p test/commonmark
	curl -fsSL https://spec.commonmark.org/0.31.2/spec.json -o $@

clean-elc:
	rm -f *.elc test/*.elc

clean: clean-elc
	rm -rf test/out

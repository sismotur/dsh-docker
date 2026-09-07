.PHONY: pdf clean-pdf

# Generate a PDF manual from README.md using pandoc + xelatex.
# Requires pandoc and a TeX distribution with xelatex (e.g. MacTeX).
pdf:
	pandoc README.md \
	  -o dsh-manual.pdf \
	  --pdf-engine=xelatex \
	  -V geometry:margin=2.5cm \
	  -V monofont=Menlo \
	  -V fontsize=10pt \
	  -V linkcolor=blue \
	  -V urlcolor=blue \
	  --syntax-highlighting=none \
	  --toc \
	  --toc-depth=3 \
	  -V toc-title="Table of contents" \
	  --metadata title="dsh — hardened Docker setup"

clean-pdf:
	rm -f dsh-manual.pdf

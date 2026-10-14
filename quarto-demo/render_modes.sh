#!/bin/bash
# Render quarto-demo/report.qmd in six ways and record, for each, where the
# code ran and which allocation it got (-> results/quarto_modes.csv).
# Run from the project root inside your Workbench session:
#   bash quarto-demo/render_modes.sh
set -e
QUARTO=$(command -v quarto || echo /usr/lib/rstudio-server/bin/quarto/bin/quarto)
QMD=quarto-demo/report.qmd
OUT=quarto-demo/rendered
mkdir -p $OUT logs
rm -f results/quarto_modes.csv

# render <name> <quarto args...>: self-contained HTML -> $OUT/<name>.html
# (renders one at a time: they share quarto-demo/report.html)
render="render() { name=\$1; shift; $QUARTO render $QMD \"\$@\" --quiet && mv quarto-demo/report.html $OUT/\$name.html; }"
eval "$render"

# 1. Chunks run in the session's R console (what "Run All" does)
# (purl() writes the YAML params into the script, so set them afterwards)
Rscript -e '
knitr::purl("quarto-demo/report.qmd", output = tf <- tempfile(fileext = ".R"), quiet = TRUE)
code <- sub("mode = \"interactive\"", "mode = \"1 session console\"", readLines(tf), fixed = TRUE)
writeLines(code, tf); source(tf)'

# 2. quarto render from the session (terminal or Render button)
render session -P mode:"2 render in session"

# 3. quarto render as its own SLURM job
sbatch --wait --parsable -p compute -c 4 --mem=4G -t 15 -J quarto-render -o logs/%x-%j.out \
  --wrap "$render; render sbatch -P mode:'3 sbatch -c 4'"

# 3b. the same job with 1 CPU: future_map() gets 1 worker
sbatch --wait --parsable -p compute -c 1 --mem=2G -t 15 -J quarto-render -o logs/%x-%j.out \
  --wrap "$render; render sbatch-1cpu -P mode:'3b sbatch -c 1'"

# 4. render in the session, parallel work on mirai daemons = SLURM jobs
render session-daemons -P mode:"4 render in session + daemons" -P slurm_daemons:true

# 5. a small render job that only orchestrates; the daemons do the work
sbatch --wait --parsable -p compute -c 1 --mem=2G -t 15 -J quarto-render -o logs/%x-%j.out \
  --wrap "$render; render sbatch-daemons -P mode:'5 sbatch -c 1 + daemons' -P slurm_daemons:true"

Rscript -e 'print(read.csv("results/quarto_modes.csv")[c("mode", "host", "slurm_job", "available_cores", "detect_cores", "mem_limit_mb", "workers", "worker_hosts", "tasks_s")])'

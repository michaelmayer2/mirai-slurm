options(repos = BiocManager::repositories())

db <- tools::CRAN_package_db()

gpu <- db[
  grepl("cuda|opencl|nvidia|gpu", db$SystemRequirements, ignore.case = TRUE) |
    grepl("\\bGPU|CUDA|OpenCL", db$Description, ignore.case = FALSE),
  c("Package", "Title")
]

gpu <- gpu[!duplicated(gpu$Package), ]

# Reverse dependencies across all repos in getOption("repos") (CRAN + Bioconductor)
ap <- available.packages()
revdeps <- function(which) {
  tools::package_dependencies(
    gpu$Package,
    db = ap,
    which = which,
    reverse = TRUE
  )
}
strong <- revdeps(c("Depends", "Imports", "LinkingTo"))
weak <- revdeps("Suggests")

fmt <- function(x, max = 8) {
  x <- sort(x)
  if (length(x) > max) {
    paste0(paste(x[1:max], collapse = ", "), ", … (+", length(x) - max, ")")
  } else {
    paste(x, collapse = ", ")
  }
}

gpu$n_revdeps <- lengths(strong[gpu$Package])
gpu$revdeps <- vapply(strong[gpu$Package], fmt, character(1))
gpu$n_suggested_by <- lengths(weak[gpu$Package])

tbl <- gpu[order(-gpu$n_revdeps, gpu$Package), ]
rownames(tbl) <- NULL
#tbl$SystemRequirements <- strtrim(gsub("\\s+", " ", tbl$SystemRequirements), 60)
tbl$Title <- strtrim(tbl$Title, 60)

gt::gt(tbl) |>
  gt::tab_header(
    title = "CRAN/Bioconductor packages mentioning GPU / CUDA / OpenCL",
    subtitle = "Reverse dependencies from CRAN + Bioconductor"
  ) |>
  gt::cols_label(
    n_revdeps = "Rev. deps",
    revdeps = "Depends / Imports / LinkingTo",
    n_suggested_by = "Suggested by"
  )


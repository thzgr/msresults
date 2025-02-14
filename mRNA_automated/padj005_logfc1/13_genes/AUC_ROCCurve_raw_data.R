suppressMessages(
    suppressWarnings({
        library(GEOquery)
        library(ROCR)
        library(dplyr)
        library(biomaRt)
        library(stringr)
    })
)

get_annotation <- function(organism = NULL) {
    if (organism %in% c("mmu", "mmusculus_gene_ensembl")) {
        org_ensembl <- "mmusculus_gene_ensembl"
    } else if (organism %in% c("hsa", "hsapiens_gene_ensembl")) {
        org_ensembl <- "hsapiens_gene_ensembl"
    } else {
        stop("Organism needs to be passed as either mmu or hsa.")
    }

    biomart_dataset <- biomaRt::useMart(biomart = "ensembl",
        dataset = org_ensembl,
        host = "https://www.ensembl.org")#"https://dec2021.archive.ensembl.org")
    attributes_BM <- biomaRt::getBM(
        attributes = c("ensembl_transcript_id", "transcript_version",
            "ensembl_gene_id", "external_gene_name", "description",
            "transcript_biotype", "entrezgene_id", "illumina_humanwg_6_v3",
            "affy_hg_u133_plus_2"),
                                    mart = biomart_dataset)
    attributes_BM <- dplyr::rename(attributes_BM,
        target_id = ensembl_transcript_id, ens_gene = ensembl_gene_id,
        ext_gene = external_gene_name, entrez_id = entrezgene_id,
        illumina = illumina_humanwg_6_v3, affy = affy_hg_u133_plus_2)
    attributes_BM <- dplyr::select(attributes_BM,
        c("ext_gene", "entrez_id", "illumina", "affy")) %>%
                        dplyr::mutate(entrez_id = as.character(entrez_id))

    return(unique(attributes_BM))
}

Sys.setenv(VROOM_CONNECTION_SIZE = "500000")

except_get_expression <- function(gse, annot_gpl, gpl, samples,
annotation_data, gene_names_filter, labels) {
    gset <- GEOquery::getGEO(gse, GSEMatrix = TRUE, AnnotGPL = annot_gpl)
    if (length(gset) > 1) idx <- grep(gpl, attr(gset, "names")) else idx <- 1
    gset <- gset[[idx]]

    # make proper column names to match toptable
    fvarLabels(gset) <- make.names(fvarLabels(gset))

    # group membership for all samples
    gsms <- samples
    sml <- strsplit(gsms, split = "")[[1]]

    # filter out excluded samples (marked as "X")
    sel <- which(sml != "X")
    sml <- sml[sel]
    gset <- gset[, sel]

    # log2 transformation
    ex <- exprs(gset)
    qx <- as.numeric(quantile(ex,
        c(0., 0.25, 0.5, 0.75, 0.99, 1.0), na.rm = TRUE))
    LogC <- (qx[5] > 100) ||
            (qx[6] - qx[1] > 50 && qx[2] > 0)
    if (LogC) {
        ex[which(ex <= 0)] <- NaN
        exprs(gset) <- log2(ex)
    }

    expression_data <- as.data.frame(exprs(gset))
    expression_data$illumina <- row.names(expression_data)
    expression_data <- expression_data %>%
        dplyr::mutate(illumina = stringr::str_replace(illumina, "_at", ""))
    expression_data$entrez_id <- expression_data$illumina

    exp_data_att <- expression_data %>%
                    dplyr::left_join(annotation_data,
                                by = c("entrez_id"))

    exp_data_filtered <- dplyr::filter(exp_data_att,
        ext_gene %in% gene_names_filter) %>%
                            dplyr::distinct(ext_gene, .keep_all = TRUE)

    row.names(exp_data_filtered) <- exp_data_filtered$ext_gene

    exp_data_filtered <- dplyr::select(exp_data_filtered,
        -c("illumina.x", "illumina.y", "entrez_id", "ext_gene", "affy")) %>%
                            t() %>%
                            as.data.frame()

    exp_data_filtered$labels <- labels

    return(exp_data_filtered)
}

common_get_expression <- function(gse, annot_gpl, gpl, samples,
annotation_data, gene_names_filter, labels) {
    gset <- GEOquery::getGEO(gse, GSEMatrix = TRUE, AnnotGPL = annot_gpl)
    if (length(gset) > 1) idx <- grep(gpl, attr(gset, "names")) else idx <- 1
    gset <- gset[[idx]]

    # make proper column names to match toptable
    fvarLabels(gset) <- make.names(fvarLabels(gset))

    # group membership for all samples
    gsms <- samples
    sml <- strsplit(gsms, split = "")[[1]]

    # filter out excluded samples (marked as "X")
    sel <- which(sml != "X")
    sml <- sml[sel]
    gset <- gset[, sel]

    # log2 transformation
    ex <- exprs(gset)
    qx <- as.numeric(quantile(ex,
        c(0., 0.25, 0.5, 0.75, 0.99, 1.0), na.rm = TRUE))
    LogC <- (qx[5] > 100) ||
            (qx[6] - qx[1] > 50 && qx[2] > 0)
    if (LogC) {
        ex[which(ex <= 0)] <- NaN
        exprs(gset) <- log2(ex)
    }

    expression_data <- as.data.frame(exprs(gset))
    expression_data$illumina <- row.names(expression_data)

    exp_data_att <- expression_data %>%
                    dplyr::left_join(annotation_data,
                                by = c("illumina"))

    exp_data_filtered <- dplyr::filter(exp_data_att,
        ext_gene %in% gene_names_filter) %>%
                            dplyr::distinct(ext_gene, .keep_all = TRUE)

    row.names(exp_data_filtered) <- exp_data_filtered$ext_gene
    exp_data_filtered <- dplyr::select(exp_data_filtered,
        -c("illumina", "entrez_id", "ext_gene", "affy")) %>%
                            t() %>%
                            as.data.frame()

    exp_data_filtered$labels <- labels
    return(exp_data_filtered)
}

gene_names_filter <- c("FOS", "IGFBP1", "IGFBP2", "THBS1", "IRS2", "SOCS2",
"UBD", "GADD45G", "DNMT3L", "GOLM1", "ANGPTL8", "EFHD1", "CRISPLD2", "labels")

super_df <- data.frame(matrix(ncol = 14, nrow = 0))
colnames(super_df) <- gene_names_filter

datasets <- list(
    list("GSE33814",
        TRUE,
        "GPL6884",
        "1XXX1X111111111XX1XXXXXX000XX0XXX00000X00X00",
        c(TRUE, TRUE, TRUE, TRUE, TRUE, TRUE, TRUE, TRUE, TRUE, TRUE,
            TRUE, TRUE, FALSE, FALSE, FALSE, FALSE, FALSE, FALSE, FALSE,
            FALSE, FALSE, FALSE, FALSE, FALSE, FALSE)),
    list("GSE89632",
        FALSE,
        "GPL14951",
        "X1XXXXXX11X11XX111X1X111XXXX1X11111X10000000000000000X000X00000",
        c(TRUE, TRUE, TRUE, TRUE, TRUE, TRUE, TRUE,
            TRUE, TRUE, TRUE, TRUE, TRUE, TRUE, TRUE, TRUE,
            TRUE, TRUE, TRUE, TRUE, FALSE, FALSE,
            FALSE, FALSE, FALSE, FALSE, FALSE, FALSE, FALSE,
            FALSE, FALSE, FALSE, FALSE, FALSE, FALSE,
            FALSE, FALSE, FALSE, FALSE, FALSE, FALSE, FALSE, FALSE, FALSE)),
    list("GSE37031",
        FALSE,
        "GPL14877",
        "111111110000000",
        c(TRUE, TRUE, TRUE, TRUE, TRUE, TRUE, TRUE,
            TRUE, FALSE, FALSE, FALSE, FALSE, FALSE, FALSE, FALSE))
    # list("GSE164760",
    #     FALSE,
    #     "GPL13667",
    #     "000000XXXXXXXX11111111111111111111111111111111111111111111111111111111111111111111111111XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX",
    #     c(FALSE, FALSE, FALSE, FALSE, FALSE, FALSE, 
    #         TRUE, TRUE, TRUE, TRUE, TRUE, TRUE, TRUE, 
    #         TRUE, TRUE, TRUE, TRUE, TRUE, TRUE, TRUE, 
    #         TRUE, TRUE, TRUE, TRUE, TRUE, TRUE, TRUE, 
    #         TRUE, TRUE, TRUE, TRUE, TRUE, TRUE, TRUE, 
    #         TRUE, TRUE, TRUE, TRUE, TRUE, TRUE, TRUE, 
    #         TRUE, TRUE, TRUE, TRUE, TRUE, TRUE, TRUE, 
    #         TRUE, TRUE, TRUE, TRUE, TRUE, TRUE, TRUE, 
    #         TRUE, TRUE, TRUE, TRUE, TRUE, TRUE, TRUE, 
    #         TRUE, TRUE, TRUE, TRUE, TRUE, TRUE, TRUE, 
    #         TRUE, TRUE, TRUE, TRUE, TRUE, TRUE, TRUE, 
    #         TRUE, TRUE, TRUE, TRUE))
)

ann <- get_annotation(organism = "hsa")

for (d in datasets){
    if (d[[1]] == "GSE37031") {
        data <- except_get_expression(
            d[[1]],
            d[[2]],
            d[[3]],
            d[[4]],
            ann,
            gene_names_filter,
            d[[5]])
    } else {
        data <- common_get_expression(
            d[[1]],
            d[[2]],
            d[[3]],
            d[[4]],
            ann,
            gene_names_filter,
            d[[5]])
    }
    #print(as.character(d[[1]]))
    #print(head(data, 5))
    #print("")
    super_df <- dplyr::bind_rows(super_df, data)
}

gene_panel <- c("ANGPTL8", "UBD")


if (length(gene_panel) > 0) {
    panel_dataframe <- data.frame(
        panel=numeric(),
        labels=logical()
    )
    for (gene in gene_panel) {
        current <- na.omit(dplyr::select(super_df, c(gene, "labels"))) %>%
                    dplyr::rename(panel=gene)
        panel_dataframe <- dplyr::union_all(panel_dataframe, current)
        print(head(current))
    }
    print("")
    print(head(panel_dataframe))
    pred <- ROCR::prediction(panel_dataframe[["panel"]], panel_dataframe[["labels"]])
    auc <- ROCR::performance(pred, "auc")
    print(paste(auc@y.name, paste0(gene_panel, collapse = " + ")))
    print(as.character(auc@y.values))
    print("")
} else {
    for (col in gene_names_filter){
        if (col %in% names(super_df) && col != "labels") {
            curr_df <- na.omit(dplyr::select(super_df, c(col, "labels")))
            if (nrow(curr_df) == 0) {
                print("")
                print(paste("No rows for", col, "after `na.omit`"))
                print("")
            } else {
                pred <- ROCR::prediction(curr_df[[col]], curr_df[["labels"]])

                # para ter performance perf <- ROCR::performance(pred, "tpr", "fpr")

                auc <- ROCR::performance(pred, "auc")

                print("")
                print(paste(auc@y.name, col))
                print(as.character(auc@y.values))
                print("")
                #  para plotar performance ROCR::plot(perf)
            }


        } else {
            print("")
            print(paste("No column for", col))
            print("")
        }
    }
}
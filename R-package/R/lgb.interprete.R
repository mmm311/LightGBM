#' Compute feature contribution of prediction
#' 
#' Computes feature contribution components of rawscore prediction.
#' 
#' @param model object of class \code{lgb.Booster}.
#' @param data a matrix object or a dgCMatrix object.
#' @param idxset a integer vector of indices of rows needed.
#' @param num_iteration number of iteration want to predict with, NULL or <= 0 means use best iteration.
#' 
#' @return
#' 
#' For regression, binary classification and lambdarank model, a \code{list} of \code{data.table} with the following columns:
#' \itemize{
#'   \item \code{Feature} Feature names in the model.
#'   \item \code{Contribution} The total contribution of this feature's splits.
#' }
#' For multiclass classification, a \code{list} of \code{data.table} with the Feature column and Contribution columns to each class.
#' 
#' @examples
#' \dontrun{
#' library(lightgbm)
#' Sigmoid <- function(x) 1 / (1 + exp(-x))
#' Logit <- function(x) log(x / (1 - x))
#' data(agaricus.train, package = "lightgbm")
#' train <- agaricus.train
#' dtrain <- lgb.Dataset(train$data, label = train$label)
#' setinfo(dtrain, "init_score", rep(Logit(mean(train$label)), length(train$label)))
#' data(agaricus.test, package = "lightgbm")
#' test <- agaricus.test
#'
#' params = list(objective = "binary",
#'               learning_rate = 0.01, num_leaves = 63, max_depth = -1,
#'               min_data_in_leaf = 1, min_sum_hessian_in_leaf = 1)
#'               model <- lgb.train(params, dtrain, 20)
#' model <- lgb.train(params, dtrain, 20)
#'
#' tree_interpretation <- lgb.interprete(model, test$data, 1:5)
#' }
#' 
#' @importFrom magrittr %>% %T>%
#' @export
lgb.interprete <- function(model,
                           data,
                           idxset,
                           num_iteration = NULL) {
  
  # Get tree model
  tree_dt <- lgb.model.dt.tree(model, num_iteration)
  
  # Check number of classes
  num_class <- model$.__enclos_env__$private$num_class
  
  # Get vector list
  tree_interpretation_dt_list <- vector(mode = "list", length = length(idxset))
  
  # Get parsed predictions of data
  leaf_index_mat_list <- model$predict(data[idxset, , drop = FALSE],
                                       num_iteration = num_iteration,
                                       predleaf = TRUE) %>%
    t(.) %>%
    data.table::as.data.table(.) %>%
    lapply(., FUN = function(x) matrix(x, ncol = num_class, byrow = TRUE))
  
  # Get list of trees
  tree_index_mat_list <- lapply(leaf_index_mat_list,
                                FUN = function(x) matrix(seq_len(length(x)) - 1, ncol = num_class, byrow = TRUE))
  
  # Sequence over idxset
  for (i in seq_along(idxset)) {
    tree_interpretation_dt_list[[i]] <- single.row.interprete(tree_dt, num_class, tree_index_mat_list[[i]], leaf_index_mat_list[[i]])
  }
  
  # Return interpretation list
  return(tree_interpretation_dt_list)
  
}

single.tree.interprete <- function(tree_dt,
                                   tree_id,
                                   leaf_id) {
  
  # Match tree id
  single_tree_dt <- tree_dt[tree_index == tree_id, ]
  
  # Get leaves
  leaf_dt <- single_tree_dt[leaf_index == leaf_id, .(leaf_index, leaf_parent, leaf_value)]
  
  # Get nodes
  node_dt <- single_tree_dt[!is.na(split_index), .(split_index, split_feature, node_parent, internal_value)]
  
  # Prepare sequences
  feature_seq <- character(0)
  value_seq <- numeric(0)
  
  # Get to root from leaf
  leaf_to_root <- function(parent_id, current_value) {
    
    # Store value
    value_seq <<- c(current_value, value_seq)
    
    # Check for null parent id
    if (!is.na(parent_id)) {
      
      # Not null means existing node
      this_node <- node_dt[split_index == parent_id, ]
      feature_seq <<- c(this_node[["split_feature"]], feature_seq)
      leaf_to_root(this_node[["node_parent"]], this_node[["internal_value"]])
      
    }
    
  }
  
  # Perform leaf to root conversion
  leaf_to_root(leaf_dt[["leaf_parent"]], leaf_dt[["leaf_value"]])
  
  # Return formatted data.table
  data.table::data.table(Feature = feature_seq, Contribution = diff.default(value_seq))
  
}

multiple.tree.interprete <- function(tree_dt,
                                     tree_index,
                                     leaf_index) {
  
  # Apply each trees
  mapply(single.tree.interprete,
         tree_id = tree_index, leaf_id = leaf_index,
         MoreArgs = list(tree_dt = tree_dt),
         SIMPLIFY = FALSE, USE.NAMES = TRUE) %>%
    data.table::rbindlist(., use.names = TRUE) %>%
    magrittr::extract(., j = .(Contribution = sum(Contribution)), by = "Feature") %>%
    magrittr::extract(., i = order(abs(Contribution), decreasing = TRUE))
  
}

single.row.interprete <- function(tree_dt, num_class, tree_index_mat, leaf_index_mat) {
  
  # Prepare vector list
  tree_interpretation <- vector(mode = "list", length = num_class)
  
  # Loop throughout each class
  for (i in seq_len(num_class)) {
    
    tree_interpretation[[i]] <- multiple.tree.interprete(tree_dt, tree_index_mat[,i], leaf_index_mat[,i]) %T>% {
      
      # Number of classes larger than 1 requires adjustment
      if (num_class > 1) {
        data.table::setnames(., old = "Contribution", new = paste("Class", i - 1))
      }
    }
    
  }
  
  # Check for numbe rof classes larger than 1
  if (num_class == 1) {
    
    # First interpretation element
    tree_interpretation_dt <- tree_interpretation[[1]]
    
  } else {
    
    # Full interpretation elements
    tree_interpretation_dt <- Reduce(f = function(x, y) merge(x, y, by = "Feature", all = TRUE),
                                     x = tree_interpretation)
    
    # Loop throughout each tree
    for (j in 2:ncol(tree_interpretation_dt)) {
      
      data.table::set(tree_interpretation_dt,
                      i = which(is.na(tree_interpretation_dt[[j]])),
                      j = j,
                      value = 0)
      
    }
    
  }
  
  # Return interpretation tree
  return(tree_interpretation_dt)
}

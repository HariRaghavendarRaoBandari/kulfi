open Core.Std
open Frenetic_Network
open Net
open AutoTimer
open Kulfi_Types
open Kulfi_Util
open Simulate_Switch
open Simulation_Types
open Simulation_Util

let demand_envelope = ref SrcDstMap.empty

let solver_to_string (s:solver_type) : string =
  match s with
  | Ac -> "ac"
  | AkEcmp -> "akecmp"
  | AkKsp -> "akksp"
  | AkMcf -> "akmcf"
  | AkRaeke -> "akraeke"
  | AkVlb -> "akvlb"
  | Ecmp -> "ecmp"
  | Edksp -> "edksp"
  | Ffc -> "ffc"
  | Ffced -> "ffced"
  | Ksp -> "ksp"
  | Mcf -> "mcf"
  | MwMcf -> "mwmcf"
  | Raeke -> "raeke"
  | SemiMcfAc -> "semimcfac"
  | SemiMcfEcmp -> "semimcfecmp"
  | SemiMcfEdksp -> "semimcfedksp"
  | SemiMcfKsp -> "semimcfksp"
  | SemiMcfKspFT -> "semimcfkspft"
  | SemiMcfMcf -> "semimcfmcf"
  | SemiMcfMcfEnv -> "semimcfmcfenv"
  | SemiMcfMcfFTEnv -> "semimcfmcfftenv"
  | SemiMcfRaeke -> "semimcfraeke"
  | SemiMcfRaekeFT -> "semimcfraekeft"
  | SemiMcfVlb -> "semimcfvlb"
  | Spf -> "spf"
  | Vlb -> "vlb"
  | OptimalMcf -> "optimalmcf"

let select_algorithm solver = match solver with
  | Ac -> Kulfi_Routing.Ac.solve
  | AkEcmp
  | AkKsp
  | AkMcf
  | AkRaeke
  | AkVlb -> Kulfi_Routing.Ak.solve
  | Ecmp -> Kulfi_Routing.Ecmp.solve
  | Edksp -> Kulfi_Routing.Edksp.solve
  | Ffc
  | Ffced -> Kulfi_Routing.Ffc.solve
  | Ksp -> Kulfi_Routing.Ksp.solve
  | Mcf -> Kulfi_Routing.Mcf.solve
  | MwMcf -> Kulfi_Routing.MwMcf.solve
  | OptimalMcf -> Kulfi_Routing.Mcf.solve
  | Raeke -> Kulfi_Routing.Raeke.solve
  | SemiMcfAc
  | SemiMcfEcmp
  | SemiMcfEdksp
  | SemiMcfKsp
  | SemiMcfKspFT
  | SemiMcfMcf
  | SemiMcfMcfEnv
  | SemiMcfMcfFTEnv
  | SemiMcfRaeke
  | SemiMcfRaekeFT
  | SemiMcfVlb -> Kulfi_Routing.SemiMcf.solve
  | Spf -> Kulfi_Routing.Spf.solve
  | Vlb -> Kulfi_Routing.Vlb.solve

let select_local_recovery solver = match solver with
  | Ac -> Kulfi_Routing.Ac.local_recovery
  | AkEcmp
  | AkKsp
  | AkMcf
  | AkRaeke
  | AkVlb -> Kulfi_Routing.Ak.local_recovery
  | Ecmp -> Kulfi_Routing.Ecmp.local_recovery
  | Edksp -> Kulfi_Routing.Edksp.local_recovery
  | Ffc
  | Ffced -> Kulfi_Routing.Ffc.local_recovery
  | Ksp -> Kulfi_Routing.Ksp.local_recovery
  | Mcf -> Kulfi_Routing.Mcf.local_recovery
  | MwMcf -> Kulfi_Routing.MwMcf.local_recovery
  | OptimalMcf -> failwith "No local recovery for optimal mcf"
  | Raeke -> Kulfi_Routing.Raeke.local_recovery
  | SemiMcfAc
  | SemiMcfEcmp
  | SemiMcfEdksp
  | SemiMcfKsp
  | SemiMcfKspFT
  | SemiMcfMcf
  | SemiMcfMcfEnv
  | SemiMcfMcfFTEnv
  | SemiMcfRaeke
  | SemiMcfRaekeFT
  | SemiMcfVlb -> Kulfi_Routing.SemiMcf.local_recovery
  | Spf -> Kulfi_Routing.Spf.local_recovery
  | Vlb -> Kulfi_Routing.Vlb.local_recovery

(* compute routing schemes for each link failure and merge the schemes *)
let all_failures_envelope solver (topo:topology) (envelope:demands) : scheme =
  let hosts = get_hosts topo in
  let failure_scheme_map,_ = EdgeSet.fold (Topology.edges topo)
    ~init:(EdgeMap.empty, EdgeSet.empty)
    ~f:(fun (acc, handled_edges) e ->
      if (EdgeSet.mem handled_edges e) then (acc, handled_edges)
      else
        let e' = match Topology.inverse_edge topo e with
          | None ->
              Printf.printf "%s\n%!" (string_of_edge topo e);
              failwith "No reverse edge found"
          | Some x -> x in
        let handled_edges = EdgeSet.add (EdgeSet.add handled_edges e) e' in
        let failure_scen = EdgeSet.add (EdgeSet.singleton e) e' in
        if edge_connects_switches e topo then
          let topo' = EdgeSet.fold failure_scen
            ~init:topo
            ~f:(fun acc link -> Topology.remove_edge acc link) in
          (* consider only the failures which do not partition the network *)
          let spf_scheme = Kulfi_Spf.solve topo' SrcDstMap.empty in
          if all_pairs_connectivity topo' hosts spf_scheme then
            begin
            let sch = solver topo' envelope in
            assert (not (SrcDstMap.is_empty sch));
            (EdgeMap.add ~key:e ~data:sch acc, handled_edges)
            end
          else (acc, handled_edges)
        else (acc, handled_edges)) in
  (* merge all the schemes *)
  assert (not (EdgeMap.is_empty failure_scheme_map));
  let agg_scheme = EdgeMap.fold failure_scheme_map
    ~init:SrcDstMap.empty
    ~f:(fun ~key:e ~data:edge_scheme agg ->
      (* merge edge_schme and agg *)
      assert (not (SrcDstMap.is_empty edge_scheme));
      SrcDstMap.fold edge_scheme
        ~init:agg
        ~f:(fun ~key:(s,d) ~data:f_pp_map res ->
          if s = d then res else
          let acc_pp_map = match SrcDstMap.find res (s,d) with
            | None -> PathMap.empty
            | Some x -> x in
          if (PathMap.is_empty f_pp_map) then
            begin
              Printf.printf "sd: (%s, %s) Edge: %s: Scheme %s"
                (string_of_vertex topo s) (string_of_vertex topo d)
                (string_of_edge topo e) (dump_scheme topo edge_scheme);
              assert false
            end
          else
          let n_pp_map = PathMap.fold f_pp_map
            ~init:acc_pp_map
            ~f:(fun ~key:path ~data:f_prob acc_paths ->
              let acc_prob = match PathMap.find acc_paths path with
                | None -> 0.
                | Some x -> x in
              PathMap.add ~key:path ~data:(acc_prob +. f_prob) acc_paths) in
          SrcDstMap.add ~key:(s,d) ~data:n_pp_map res)) in
  (* normalize scheme *)
  assert (not (SrcDstMap.is_empty agg_scheme));
  normalize_scheme_opt agg_scheme

(* Compute the initial scheme for a TE algorithm *)
let initial_scheme algorithm topo predict : scheme =
  match algorithm with
  | SemiMcfAc ->
    let _ = Kulfi_Routing.Ac.initialize SrcDstMap.empty in
    Kulfi_Routing.Ac.solve topo SrcDstMap.empty
  | AkEcmp
  | SemiMcfEcmp ->
    let _ = Kulfi_Routing.Ecmp.initialize SrcDstMap.empty in
    Kulfi_Routing.Ecmp.solve topo SrcDstMap.empty
  | Ffced
  | SemiMcfEdksp ->
    let _ = Kulfi_Routing.Edksp.initialize SrcDstMap.empty in
    Kulfi_Routing.Edksp.solve topo SrcDstMap.empty
  | AkKsp
  | Ffc
  | SemiMcfKsp ->
    let _ = Kulfi_Routing.Ksp.initialize SrcDstMap.empty in
    Kulfi_Routing.Ksp.solve topo SrcDstMap.empty
  | SemiMcfKspFT ->
    let _ = Kulfi_Routing.Ksp.initialize SrcDstMap.empty in
    all_failures_envelope Kulfi_Routing.Ksp.solve topo SrcDstMap.empty
  | AkMcf
  | SemiMcfMcf ->
    Kulfi_Routing.Mcf.solve topo predict
  | SemiMcfMcfEnv ->
    Kulfi_Routing.Mcf.solve topo !demand_envelope
  | SemiMcfMcfFTEnv ->
    all_failures_envelope Kulfi_Routing.Mcf.solve topo !demand_envelope
  | AkRaeke
  | SemiMcfRaeke ->
    let _ = Kulfi_Routing.Raeke.initialize SrcDstMap.empty in
    Kulfi_Routing.Raeke.solve topo SrcDstMap.empty
  | SemiMcfRaekeFT ->
    let _ = Kulfi_Routing.Raeke.initialize SrcDstMap.empty in
    all_failures_envelope Kulfi_Routing.Raeke.solve topo SrcDstMap.empty
  | AkVlb
  | SemiMcfVlb ->
    let _ = Kulfi_Routing.Vlb.initialize SrcDstMap.empty in
    Kulfi_Routing.Vlb.solve topo SrcDstMap.empty
  | _ -> SrcDstMap.empty

(* Initialize a TE algorithm *)
let initialize_scheme algorithm topo predict : unit =
  let start_scheme = initial_scheme algorithm topo predict in
  let pruned_scheme =
    if SrcDstMap.is_empty start_scheme then start_scheme
    else prune_scheme topo start_scheme !Kulfi_Globals.budget in
  match algorithm with
  | Ac -> Kulfi_Routing.Ac.initialize SrcDstMap.empty
  | AkEcmp
  | AkKsp
  | AkMcf
  | AkRaeke
  | AkVlb -> Kulfi_Routing.Ak.initialize pruned_scheme
  | Ecmp -> Kulfi_Routing.Ecmp.initialize SrcDstMap.empty
  | Edksp -> Kulfi_Routing.Edksp.initialize SrcDstMap.empty
  | Ffc
  | Ffced -> Kulfi_Routing.Ffc.initialize pruned_scheme
  | Ksp -> Kulfi_Routing.Ksp.initialize SrcDstMap.empty
  | Raeke -> Kulfi_Routing.Raeke.initialize SrcDstMap.empty
  | SemiMcfAc
  | SemiMcfEcmp
  | SemiMcfEdksp
  | SemiMcfKsp
  | SemiMcfKspFT
  | SemiMcfMcf
  | SemiMcfMcfEnv
  | SemiMcfMcfFTEnv
  | SemiMcfRaeke
  | SemiMcfRaekeFT
  | SemiMcfVlb -> Kulfi_Routing.SemiMcf.initialize pruned_scheme
  | Vlb -> Kulfi_Routing.Vlb.initialize SrcDstMap.empty
  | _ -> ()



(* Compute a routing scheme for an algorithm and apply budget by pruning the top-k paths *)
let solve_within_budget algorithm topo predict actual : (scheme * float) =
  let at = make_auto_timer () in
  start at;
  let solve = select_algorithm algorithm in
  let budget' = match algorithm with
    | OptimalMcf ->
        Int.max_value / 100
    | _ ->
        !Kulfi_Globals.budget in
  let sch = match algorithm with
    | OptimalMcf -> (* Use actual demands for Optimal *)
        prune_scheme topo (solve topo actual) budget'
    | _ ->
        prune_scheme topo (solve topo predict) budget' in
  stop at;
  (*assert (probabilities_sum_to_one sch);*)
  (sch, (get_time_in_seconds at))

(* TODO(rjs): Do we count paths that have 0 flow ? *)
let get_churn (old_scheme:scheme) (new_scheme:scheme) : float =
  let get_path_sets (s:scheme) : PathSet.t =
    SrcDstMap.fold s
      ~init:PathSet.empty
      ~f:(fun ~key:_ ~data:d acc ->
          PathMap.fold
            ~init:acc
            ~f:(fun ~key:p ~data:_ acc ->
                PathSet.add acc p ) d) in
  let set1 = get_path_sets old_scheme in
  let set2 = get_path_sets new_scheme in
  let union = PathSet.union set1 set2 in
  let inter = PathSet.inter set1 set2 in
  Float.of_int (PathSet.length (PathSet.diff union inter))

(* compare paths based on string representation *)
let get_churn_string (topo:topology) (old_scheme:scheme) (new_scheme:scheme) : float =
  let get_path_sets (s:scheme) : StringSet.t =
    SrcDstMap.fold
      ~init:StringSet.empty
      ~f:(fun ~key:_ ~data:d acc ->
          PathMap.fold
            ~init:acc
            ~f:(fun ~key:p ~data:_ acc ->
              StringSet.add acc (dump_edges topo p)) d) s in
  let set1 = get_path_sets old_scheme in
  let set2 = get_path_sets new_scheme in
  let union = StringSet.union set1 set2 in
  let inter = StringSet.inter set1 set2 in
  Float.of_int (StringSet.length (StringSet.diff union inter))

(* Get a map from path to it's probability and src-dst demand *)
let get_path_prob_demand_map (s:scheme) (d:demands) : (probability * demand) PathMap.t =
  (* (Probability, net s-d demand) for each path *)
  SrcDstMap.fold s
    ~init:PathMap.empty
    ~f:(fun ~key:(src,dst) ~data:paths acc ->
      let demand = match SrcDstMap.find d (src,dst) with
                 | None -> 0.0
                 | Some x -> x in
      PathMap.fold paths
        ~init:acc
        ~f:(fun ~key:path ~data:prob acc ->
          match PathMap.find acc path with
            | None ->
                PathMap.add ~key:path ~data:(prob, demand) acc
            | Some x ->
                if List.is_empty path then acc
                else failwith "Duplicate paths should not be present"))

(* Get a map from path to it's probability and src-dst demand *)
let get_path_prob_demand_arr (s:scheme) (d:demands) =
  (* (Probability, net s-d demand) for each path *)
  SrcDstMap.fold s
    ~init:[]
    ~f:(fun ~key:(src,dst) ~data:paths acc ->
      let demand = match SrcDstMap.find d (src,dst) with
                 | None -> 0.0
                 | Some x -> x in
      PathMap.fold paths
        ~init:acc
        ~f:(fun ~key:path ~data:prob acc ->
          let arr_path = Array.of_list path in
          (arr_path, 0, (prob, demand))::acc))


(* Sum througput over all src-dst pairs *)
let get_total_tput (sd_tput:throughput SrcDstMap.t) : throughput =
  SrcDstMap.fold sd_tput
    ~init:0.0
    ~f:(fun ~key:_ ~data:dlvd acc ->
      acc +. dlvd)

(* Aggregate latency-tput over all sd-pairs *)
let get_aggregate_latency (sd_lat_tput_map_map:(throughput LatencyMap.t) SrcDstMap.t)
    (num_iter:int) : (throughput LatencyMap.t) =
  SrcDstMap.fold sd_lat_tput_map_map
    ~init:LatencyMap.empty
    ~f:(fun ~key:_ ~data:lat_tput_map acc ->
      LatencyMap.fold lat_tput_map
      ~init:acc
      ~f:(fun ~key:latency ~data:tput acc ->
        let prev_agg_tput = match LatencyMap.find acc latency with
                        | None -> 0.0
                        | Some x -> x in
        let agg_tput = prev_agg_tput +. (tput /. (Float.of_int num_iter)) in
        LatencyMap.add ~key:latency ~data:(agg_tput) acc))

let is_int v =
  let p = (Float.modf v) in
  let f = Float.Parts.fractional p in
  let c = Float.classify f in
  c = Float.Class.Zero

(* assumes l is sorted *)
let kth_percentile (l:float list) (k:float) : float =
  let n = List.length l in
  let x = (Float.of_int n) *. k in
  (*Printf.printf "%f / %d\n%!" x n;*)
  if n = 0 then 0. else
  if is_int x then
    let i = Int.of_float (Float.round_up x) in
    let lhs = match (List.nth l i) with
      | Some f -> f
      | None -> assert false in
    let rhs = match List.nth l (min (i+1) (n-1)) with
      | Some f -> f
      | None -> assert false in
    ((lhs +. rhs)/.2.)
  else
    let i = Int.of_float x in
    match (List.nth l i) with
    | Some f -> f
    | None -> assert false

let get_mean_congestion (l:float list) =
  (List.fold_left ~init:0. ~f:( +. )  l) /. (Float.of_int (List.length l))

let get_max_congestion (congestions:float list) : float =
  List.fold_left ~init:Float.nan ~f:(fun a acc -> Float.max_inan a acc) congestions

let get_num_paths (s:scheme) : float =
  let count = SrcDstMap.fold s
    ~init:0
    ~f:(fun ~key:_ ~data:d acc ->
      acc + (PathMap.length d)) in
  Float.of_int count

(* Generate latency percentile based on throughput *)
let get_latency_percentiles (lat_tput_map : throughput LatencyMap.t)
    (agg_dem:float) : (float LatencyMap.t) =
  let latency_percentiles,_ = LatencyMap.fold lat_tput_map
    ~init:(LatencyMap.empty,0.0)
    ~f:(fun ~key:latency ~data:tput acc ->
      let lat_percentile_map,sum_tput = acc in
      let sum_tput' = sum_tput +. tput in
      (LatencyMap.add ~key:latency ~data:(sum_tput' /. agg_dem)
      lat_percentile_map, sum_tput')) in
  latency_percentiles




(* Global recovery: recompute routing scheme after removing failed links *)
let global_recovery (failed_links:failure) (predict:demands) (actual:demands)
    (algorithm:solver_type) (topo:topology) : (scheme * float) =
  Printf.printf "\t\t\t\t\t\t\t\t\t\t\tGlobal\r";
  let topo' = EdgeSet.fold failed_links
    ~init:topo
    ~f:(fun acc link ->
      Topology.remove_edge acc link) in
  ignore(EdgeSet.iter failed_links
  ~f:(fun e -> assert ((EdgeSet.mem (Topology.edges topo) e) &&
      not (EdgeSet.mem (Topology.edges topo') e)) ););
  ignore(EdgeSet.iter (Topology.edges topo')
      ~f:(fun e -> assert (EdgeSet.mem (Topology.edges topo) e)));

  initialize_scheme algorithm topo' predict;
  let new_scheme,solver_time = solve_within_budget algorithm topo' predict actual in
  ignore (if (SrcDstMap.is_empty new_scheme) then failwith "new_scheme is empty in global driver" else ());
  Printf.printf "\t\t\t\t\t\t\t\t\t\t\tGLOBAL\r";
  new_scheme, solver_time


(* Model flash *)
let flash_decrease (x:float) (t:float) (total_t:float) : float =
  total_t *. x /. (t *. 2.0 +. total_t)

let flash_demand_t x t total_t d =
  d *. (flash_decrease x t total_t)

let total_flow_to_sink (sink) (topo:topology) (actual:demands) : float =
  let hosts = get_hosts_set topo in
  VertexSet.fold hosts ~init:0.
    ~f:(fun acc src -> if (src = sink) then acc else
      let d = SrcDstMap.find_exn actual (src,sink) in
      acc +. d)

let update_flash_demand topo sink dem flash_t per_src_flash_factor total_t: demands =
  if flash_t < 0 then dem
  else
    let hosts = get_hosts_set topo in
    VertexSet.fold hosts ~init:dem
      ~f:(fun acc src ->
        if src = sink then acc
        else
          let sd_dem =
            SrcDstMap.find_exn dem (src,sink)
            |> flash_demand_t per_src_flash_factor (Float.of_int flash_t) total_t in
          SrcDstMap.add ~key:(src,sink) ~data:sd_dem acc)

(* find the destination for flash crowd *)
let pick_flash_sinks (topo:topology) (iters:int) =
  let hosts = get_hosts topo in
  let num_hosts = List.length hosts in
  List.fold_left (range 0 iters) ~init:[]
  ~f:(fun acc n ->
    let selected = List.nth_exn hosts (n % num_hosts) in
    selected::acc)

let sum_demands (d:demands) : float =
  SrcDstMap.fold d ~init:0.
    ~f:(fun ~key:_ ~data:x acc -> acc +. x)

let sum_sink_demands (d:demands) sink : float =
  SrcDstMap.fold d ~init:0.
    ~f:(fun ~key:(src,dst) ~data:x acc ->
      if dst = sink then acc +. x
      else acc)

(***********************************************************)
(************** Simulate routing for one TM ****************)
let simulate_tm (start_scheme:scheme)
    (topo : topology)
    (dem : demands)
    (fail_edges : failure)
    (predict : demands)
    (algorithm : solver_type)
    (is_flash : bool)
    (flash_ba : float)
    (flash_sink) =
  (*
   * At each time-step:
     * For each path:
       * add traffic at source link
     * For each edge:
       * process incoming traffic based on fair share
       * add traffic to corresponding next hop links
       * or deliver to end host if last link in a path
  * *)
  let local_debug = false in
  (* Number of timesteps to simulate *)
  let num_iterations = !Kulfi_Globals.tm_sim_iters in
  (* wait for network to reach steady state *)
  let steady_state_time = 0 in
  (* wait for in-flight pkts to be delivered at the end *)
  let wait_out_time = 50 in
  (* Timestamp at which failures, if any, are introduced *)
  let failure_time =
    if (EdgeSet.is_empty fail_edges) ||
       (!Kulfi_Globals.failure_time > num_iterations)
    then Int.max_value/100
    else !Kulfi_Globals.failure_time + steady_state_time in
  let local_recovery_delay = !Kulfi_Globals.local_recovery_delay in
  let global_recovery_delay = !Kulfi_Globals.global_recovery_delay in
  let agg_dem = ref 0. in
  let agg_sink_dem = ref 0. in
  let recovery_churn = ref 0. in
  let solver_time = ref 0. in
  (*flash*)
  let flash_step_time = num_iterations/5 in
  let flash_pred_delay = 10 in

  let iterations = range 0 (num_iterations + steady_state_time + wait_out_time) in
  if local_debug then Printf.printf "%s\n%!" (dump_scheme topo start_scheme);

  (* flash *)
  agg_dem := sum_demands dem;
  let per_src_flash_factor =
    flash_ba *. !agg_dem /. (total_flow_to_sink flash_sink topo dem)
    /. (Float.of_int (List.length (get_hosts topo))) in
  if is_flash then Printf.printf "\t\t\t\t\tSink: %s\r"
      (string_of_vertex topo flash_sink);

  (* Main loop: iterate over timesteps and update network state *)
  let final_network_state =
    List.fold_left iterations
      ~init:(make_network_iter_state
               ~scheme:start_scheme ~real_tm:dem ~predict_tm:predict ())
      ~f:(fun current_state iter ->
          (* begin iteration - time *)
          Printf.printf "\t\t\t\t   %s\r%!"
            (progress_bar (iter - steady_state_time)
               (num_iterations + wait_out_time) 15);

          (* Reset stats when steady state is reached *)
          let current_state =
            if iter = steady_state_time then
              begin
                agg_dem := 0.;
                agg_sink_dem := 0.;
                { current_state with
                  delivered       = SrcDstMap.empty;
                  latency         = SrcDstMap.empty;
                  utilization     = EdgeMap.empty;
                  failure_drop    = 0.0;
                  congestion_drop = 0.0; }
              end
            else
              current_state in

          (* introduce failures *)
          let failed_links =
            if iter = failure_time then
              begin
                Printf.printf "\t\t\t\t\t\t     %s  \r"
                  (dump_edges topo (EdgeSet.elements fail_edges));
                fail_edges
              end
            else current_state.failures in

          (* update tms and scheme for flash *)
          let actual_t, predict_t, new_scheme =
            if is_flash &&
               (iter >= steady_state_time) &&
               (iter < steady_state_time + num_iterations) then
              begin
                let flash_t = iter - steady_state_time in
                if flash_t % flash_step_time = 0 then
                  begin (* update actual & pred demand  and scheme *)
                    let act' =
                      update_flash_demand topo flash_sink dem flash_t
                        per_src_flash_factor (Float.of_int num_iterations) in
                    let pred' = update_flash_demand topo flash_sink dem
                        (flash_t - flash_pred_delay) per_src_flash_factor
                        (Float.of_int num_iterations) in
                    let sch' = match algorithm with
                      | OptimalMcf ->
                        begin
                          let sch,rec_solve_time =
                            global_recovery failed_links pred' act' algorithm topo in
                          recovery_churn :=
                            !recovery_churn +. (get_churn current_state.scheme sch);
                          solver_time := !solver_time +. rec_solve_time;
                          sch
                        end
                      | _ ->
                        if !Kulfi_Globals.flash_recover then
                          (select_local_recovery algorithm) current_state.scheme
                            topo failed_links pred'
                        else current_state.scheme in
                    act',
                    pred',
                    sch'
                  end
                else
                  current_state.real_tm,
                  current_state.predict_tm,
                  current_state.scheme
              end
            else
              current_state.real_tm,
              current_state.predict_tm,
              current_state.scheme in

          (*debug*)
          (*VertexSet.iter (get_hosts_set topo)
            ~f:(fun src ->
              if not (src = flash_sink) then
              let act_d = SrcDstMap.find_exn dem (src,flash_sink) in
              let f_act_d = SrcDstMap.find_exn actual_t (src,flash_sink) in
              let p_act_d = SrcDstMap.find_exn predict_t (src,flash_sink) in
              Printf.printf "%f\t%f\n" (f_act_d /. act_d) (p_act_d /. act_d) ;);*)

          (* failures: local and global recovery *)
          let new_scheme =
            if iter < steady_state_time + num_iterations then
              match algorithm with
              | OptimalMcf ->
                if iter = failure_time then
                  begin
                    let sch,rec_solve_time =
                      global_recovery failed_links predict_t actual_t algorithm topo in
                    recovery_churn := !recovery_churn +. (get_churn new_scheme sch);
                    solver_time := !solver_time +. rec_solve_time;
                    sch
                  end
                else new_scheme
              | _ ->
                if iter = (local_recovery_delay + failure_time) then
                  ((select_local_recovery algorithm) new_scheme topo failed_links predict_t)
                else if iter = (global_recovery_delay + failure_time) then
                  begin
                    let sch,rec_solve_time =
                      global_recovery failed_links predict_t actual_t algorithm topo in
                    recovery_churn := !recovery_churn +. (get_churn new_scheme sch);
                    solver_time := !solver_time +. rec_solve_time;
                    sch
                  end
                else new_scheme
            else SrcDstMap.empty in

          (* Stop traffic generation after simulation end time *)
          let actual_t =
            if iter < (steady_state_time + num_iterations) then actual_t
            else SrcDstMap.empty in

          (* Add traffic at source of every path *)
          if iter < (num_iterations + steady_state_time) then
            agg_dem := !agg_dem +. (sum_demands actual_t);
          if iter < (num_iterations + steady_state_time) then
            agg_sink_dem := !agg_sink_dem +. (sum_sink_demands actual_t flash_sink);

          (* probability of taking each path *)
          let path_prob_arr = get_path_prob_demand_arr new_scheme actual_t in

          (* next_iter_traffic : map edge -> in_traffic in next iter *)
          let next_iter_traffic = List.fold_left path_prob_arr
              ~init:EdgeMap.empty
              ~f:(fun acc (path_arr, dist, (prob,sd_demand)) ->
                  if Array.length path_arr = 0 then acc else
                    let first_link = path_arr.(0) in
                    let sched_traf_first_link =
                      match EdgeMap.find acc first_link with
                      | None -> []
                      | Some v -> v in
                    let traf_first_link =
                      (path_arr, 1, (prob *. sd_demand))::sched_traf_first_link in
                    EdgeMap.add ~key:first_link ~data:traf_first_link acc) in

          (* if no (s-d) path, then entire demand is dropped due to failure *)
          (* if no (s-d) key, then entire demand is dropped due to failure *)
          let cumul_fail_drop = SrcDstMap.fold actual_t
              ~init:current_state.failure_drop
              ~f:(fun ~key:(src,dst) ~data:d acc ->
                  match SrcDstMap.find new_scheme (src,dst) with
                  | None ->
                    acc +. d
                  | Some x ->
                    if PathMap.is_empty x then acc +. d
                    else acc) in
          (* Done generating traffic at source *)

          (*  For each link, *)
          (*    forward fair share of flows to next links, *)
          (*    or deliver to destination *)
          let next_iter_traffic,
              new_delivered_map,
              new_lat_tput_map_map,
              new_link_utils,
              new_fail_drop,
              new_cong_drop =
            EdgeMap.fold current_state.ingress_link_traffic
              ~init:(next_iter_traffic,
                     current_state.delivered,
                     current_state.latency,
                     current_state.utilization,
                     cumul_fail_drop,
                     current_state.congestion_drop)
              ~f:(fun ~key:e ~data:in_queue_edge link_iter_acc ->
                  (* edge capacity can change due to failures *)
                  let current_edge_capacity =
                    (curr_capacity_of_edge topo e failed_links) in

                  (* total ingress traffic on link *)
                  let demand_on_link = List.fold_left in_queue_edge
                      ~init:0.0
                      ~f:(fun link_dem (_,_,flow_dem) ->
                          if is_nan flow_dem then Printf.printf "flow_dem is nan!!\n";
                          link_dem +. flow_dem) in

                  if local_debug then Printf.printf "%s: %f / %f\n%!"
                      (string_of_edge topo e) (demand_on_link /. 1e9)
                      (current_edge_capacity /. 1e9);

                  (* calculate each flow's fair share *)
                  let fs_in_queue_edge =
                    if demand_on_link <= current_edge_capacity then
                      in_queue_edge
                    else
                      fair_share_at_edge_arr current_edge_capacity in_queue_edge in

                  (* Update traffic dropped due to failure or congestion *)
                  let forwarded_by_link = List.fold_left fs_in_queue_edge
                      ~init:0.0
                      ~f:(fun fwd_acc (_,_,flow_dem) -> fwd_acc +. flow_dem) in
                  let dropped = demand_on_link -. forwarded_by_link in

                  let (_,_,_,curr_lutil_map,curr_fail_drop,curr_cong_drop) = link_iter_acc in
                  let new_fail_drop,new_cong_drop =
                    if EdgeSet.mem failed_links e then
                      curr_fail_drop +. dropped, curr_cong_drop
                    else
                      curr_fail_drop, curr_cong_drop +. dropped in
                  if (is_nan new_cong_drop) && (is_nan dropped) then
                    Printf.printf "dem = %f\tfwd = %f\n"
                      demand_on_link forwarded_by_link;

                  (* Forward/deliver traffic on this edge by iterating over
                     every flow in the ingress queue *)
                  let fl_init_nit,fl_init_dlvd_map,fl_init_ltm_map,_,_,_ = link_iter_acc in
                  let new_nit,
                      dlvd_map,
                      ltm_map =
                    List.fold_left fs_in_queue_edge
                      ~init:(fl_init_nit,
                             fl_init_dlvd_map,
                             fl_init_ltm_map)
                      ~f:(fun acc (path, dist, flow_fair_share) ->
                          let nit,dlvd_map,ltm_map = acc in
                          let next_link_opt = next_hop_arr path dist in
                          match next_link_opt with
                          | None ->
                            (* End of path, deliver traffic to dst *)
                            let (src,dst) =
                              match get_src_dst_for_path_arr path with
                              | None -> failwith "Empty path"
                              | Some x -> x in
                            (* Update delivered traffic for (src,dst) *)
                            let prev_sd_dlvd =
                              match SrcDstMap.find dlvd_map (src,dst) with
                              | None -> 0.0
                              | Some x -> x in
                            let new_dlvd = SrcDstMap.add dlvd_map
                                ~key:(src,dst)
                                ~data:(prev_sd_dlvd +. flow_fair_share) in

                            (* Update latency-tput distribution for (src,dst) *)
                            let prev_sd_ltm =
                              match SrcDstMap.find ltm_map (src,dst) with
                              | None -> LatencyMap.empty
                              | Some x -> x in
                            let path_latency = get_path_weight_arr topo path in
                            let prev_sd_tput_for_latency =
                              match LatencyMap.find prev_sd_ltm path_latency with
                              | None -> 0.0
                              | Some x -> x in
                            let new_sd_ltm = LatencyMap.add prev_sd_ltm
                                ~key:path_latency
                                ~data:(prev_sd_tput_for_latency +. flow_fair_share) in
                            let new_ltm_map = SrcDstMap.add ltm_map
                                ~key:(src,dst)
                                ~data:new_sd_ltm in
                            (nit,
                             new_dlvd,
                             new_ltm_map)
                          | Some next_link ->
                            (* Else, Forward traffic to next hop *)
                            (* Update link ingress queue for next hop *)
                            let sched_traf_next_link =
                              match EdgeMap.find nit next_link with
                              | None -> []
                              | Some v -> v in
                            if is_nan flow_fair_share then assert false;
                            let traf_next_link =
                              (path,dist+1,flow_fair_share)::sched_traf_next_link in
                            let new_nit =
                              EdgeMap.add ~key:next_link ~data:traf_next_link nit in
                            (new_nit,
                             dlvd_map,
                             ltm_map)) in
                  (* end: iteration over flows *)
                  (* log link utilization for this edge & timestep *)
                  let new_lutil_map =
                    if iter < num_iterations + steady_state_time then
                      begin
                        let curr_lutil_e =
                          match (EdgeMap.find curr_lutil_map e) with
                          | None -> []
                          | Some x -> x in
                        EdgeMap.add curr_lutil_map
                          ~key:e
                          ~data:(forwarded_by_link::curr_lutil_e)
                      end
                    else
                      curr_lutil_map in
                  (new_nit,
                   dlvd_map,
                   ltm_map,
                   new_lutil_map,
                   new_fail_drop,
                   new_cong_drop)) in
          (* Done forwarding for each link *)

          (* Print state for debugging *)
          if local_debug then
            EdgeMap.iteri next_iter_traffic
              ~f:(fun ~key:e ~data:paths_demand ->
                  Printf.printf "%s\n%!" (string_of_edge topo e);
                  List.iter paths_demand
                    ~f:(fun (path,_,d) ->
                        Printf.printf "%s\t%f\n%!"
                          (dump_edges topo (Array.to_list path)) d));
          if local_debug then SrcDstMap.iteri new_delivered_map
              ~f:(fun ~key:(src,dst) ~data:delvd ->
                  Printf.printf "%s %s\t%f\n%!"
                    (Node.name (Net.Topology.vertex_to_label topo src))
                    (Node.name (Net.Topology.vertex_to_label topo dst)) delvd);

          (* State carried over to next timestep *)
          { ingress_link_traffic  = next_iter_traffic;
            delivered             = new_delivered_map;
            latency               = new_lat_tput_map_map;
            utilization           = new_link_utils;
            scheme                = new_scheme;
            failures              = failed_links;
            failure_drop          = new_fail_drop;
            congestion_drop       = new_cong_drop;
            real_tm               = actual_t;
            predict_tm            = predict_t; })
      (* end iteration over timesteps *) in

  agg_dem := !agg_dem /. (Float.of_int num_iterations);
  agg_sink_dem := !agg_sink_dem /. (Float.of_int num_iterations);
  (* Generate stats *)
  {
    throughput =
      SrcDstMap.fold final_network_state.delivered
        ~init:SrcDstMap.empty
        ~f:(fun ~key:sd ~data:dlvd acc ->
            SrcDstMap.add acc
              ~key:sd
              ~data:(dlvd /. (Float.of_int num_iterations) /. !agg_dem));

    latency =
      get_aggregate_latency final_network_state.latency num_iterations;

    congestion =
      EdgeMap.fold final_network_state.utilization
        ~init:EdgeMap.empty
        ~f:(fun ~key:e ~data:util_list acc ->
            EdgeMap.add acc
              ~key:e
              ~data:((average_list util_list) /. (capacity_of_edge topo e),
                     (max_list util_list)    /. (capacity_of_edge topo e)));

    failure_drop =
      final_network_state.failure_drop /. (Float.of_int num_iterations) /. !agg_dem;

    congestion_drop =
      final_network_state.congestion_drop /. (Float.of_int num_iterations) /. !agg_dem;

    flash_throughput =
      if is_flash then SrcDstMap.fold final_network_state.delivered
          ~init:0.0
          ~f:(fun ~key:(src,dst) ~data:dlvd acc ->
              if dst = flash_sink then
                acc +. dlvd /. (Float.of_int num_iterations) /. !agg_sink_dem
              else acc)
      else 0.0;

    aggregate_demand = !agg_dem;
    recovery_churn = !recovery_churn;
    scheme = final_network_state.scheme;
    solver_time = !solver_time; }
(* end simulate_tm *)

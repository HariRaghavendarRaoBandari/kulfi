open Frenetic_Network
open Net
open Core.Std
open Kulfi_Types

let () = match !Kulfi_Globals.rand_seed with
  | Some x -> Random.init x
  | None -> Random.self_init ~allow_in_tests:true ()

let pi = 4.0 *. atan 1.0

type host = Topology.vertex

(* First array maps integer indices to the corresponding hosts; second
   array stores the actual demands *)
type 'a demand_matrix = host array * 'a array array

(* Phase and amplitude of a sine function *)
type sinusoid = float * float

let sample_power_law x_min alpha () =
  let x = Random.float 1.0 in
  x_min *. (1. /. ((1. -. x) ** (1. /. alpha)))

let power_law = sample_power_law 100. 1.15

type demand_model =
  (* Matrix doesn't update *)
    Static of int demand_matrix
  (* Matrix randomly updated by power law each time *)
  | IIDRandom of int demand_matrix
  (* Sparseness of differences, max diff amount, matrix*)
  | SparseDiff of float * int * int demand_matrix
  (* Frequency, time, sines *)
  | Periodic of float * int * (sinusoid demand_matrix)

(* Updates all demands in the matrix to be random integers in [0,limit) *)
let update_random matrix =
  let host_array, demand_array = matrix in
  Array.iteri (fun i _ ->
      Array.iteri (fun j _ ->
        demand_array.(i).(j) <-
          (if i = j then 0 else
             let d = power_law () in
             Int.of_float d))
        host_array)
    host_array;
  matrix

(* For each entry, with probability prob, add a random amount in
   [-diff_amt, diff_amt]. Demands have a max of limit *)
let update_sparse matrix prob diff_amt =
  let host_array, demand_array = matrix in
  Array.iteri (fun i _ ->
      Array.iteri (fun j _ ->
          if Random.float 1.0 > prob then ()
          else if i = j then ()
          else
            let new_dem = power_law () in
            demand_array.(i).(j) <- (Int.of_float new_dem))
        host_array)
    host_array;
  matrix

let update model =
  match model with
  | Static matrix -> Static matrix
  | IIDRandom (matrix) -> IIDRandom (update_random matrix)
  | SparseDiff (prob, diff, matrix) ->
    SparseDiff (prob, diff, update_sparse matrix prob diff)
  | Periodic (freq, time, matrix) -> Periodic (freq, time + 1, matrix)

let create_power_law hosts =
  let host_array = Array.of_list hosts in
  let num_hosts = List.length hosts in
  let demand_array = Array.make_matrix num_hosts num_hosts 0 in
  Array.iteri (fun i _ ->
      Array.iteri (fun j _ ->
          if i = j then () else
            let d = power_law () in
            demand_array.(i).(j) <- Int.of_float d)
        host_array)
    host_array;
  Static ((host_array, demand_array))

(* Given a list of hosts, makes a demand matrix initialized to random demands *)
let create_random hosts =
  let host_array = Array.of_list hosts in
  let num_hosts = List.length hosts in
  let demand_array = Array.make_matrix num_hosts num_hosts 0 in
  let random_matrix = update_random (host_array, demand_array) in
  IIDRandom (random_matrix)

let create_sparse hosts prob diff =
  let host_array = Array.of_list hosts in
  let num_hosts = List.length hosts in
  let demand_array = Array.make_matrix num_hosts num_hosts 0 in
  let random_matrix = update_random (host_array, demand_array) in
  SparseDiff (prob, diff, random_matrix)

let create_periodic hosts limit period =
  let freq_factor = (2. *. pi) /. period in
  let random_phase () = Random.float (2. *. pi) in
  let random_sinusoid () =
    (random_phase (), float (1 + Random.int limit)) in
  let host_array = Array.of_list hosts in
  let num_hosts = List.length hosts in
  let demand_array = Array.make_matrix num_hosts num_hosts (0., 0.) in
  Array.iteri (fun i _ ->
      Array.iteri (fun j _ ->
          if i = j then () else
            demand_array.(i).(j) <- (random_sinusoid ()))
        host_array)
    host_array;
  Periodic (freq_factor, 0, (host_array, demand_array))

let get_demands model =
  match model with
  | Static ((hosts, ds))
  | IIDRandom ((hosts, ds)) | SparseDiff (_,_,(hosts,ds)) ->
    let lst = ref [] in
    Array.iteri (fun i h_i ->
        Array.iteri (fun j h_j ->
            let d = ds.(i).(j) in
            if i = j || d = 0 then () else
              lst := (hosts.(i), hosts.(j), float d)::(!lst))
          hosts)
      hosts;
    !lst
  | Periodic (freq,time,(hosts, demand_fns)) ->
    let lst = ref [] in
    Array.iteri (fun i h_i ->
        Array.iteri (fun j h_j ->
            if i = j then () else
              let (phase,amp) = demand_fns.(i).(j) in
              let t = float time in
              let d = phase *. sin (freq *. (t +. phase)) in
              if d = 0. then () else
                lst := (hosts.(i), hosts.(j), d)::(!lst))
          hosts)
      hosts;
    !lst

let demand_list_to_map (demand_list:(host * host * float) list) : Kulfi_Types.demands =
  List.fold_left ~init:SrcDstMap.empty ~f:(fun acc (u,v,r) -> SrcDstMap.add acc ~key:(u,v) ~data:r) demand_list

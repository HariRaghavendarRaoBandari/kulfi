open Core.Std
open Frenetic_Network
open Net      
open Kulfi_Types
open Kulfi_Routing
open Simulate_Exps
open RunningStat
open ExperimentalData 
open AutoTimer
       
type solver_type = | Mcf | Vlb | Ecmp | Spf | Ak | NaS (*not a solver*)
let solver_mode = ref NaS
let topo_string = ref ""
let iterations = ref 0
let usage = Printf.sprintf "%s -s [solver] -t [topology] -i [iterations]\n" Sys.argv.(0)
let solver_to_string (s:solver_type) : string =
  match s with 
  | Mcf -> "mcf" 
  | Vlb -> "vlb" 
  | Ecmp -> "ecmp"
  | Spf -> "spf" 
  | Ak -> "ak" 
  | _ -> raise (Arg.Bad("Unknown solver"))

let choose_solver = function
  | "mcf" -> solver_mode := Mcf
  | "vlb" -> solver_mode := Vlb
  | "ecmp" -> solver_mode := Ecmp
  | "spf" -> solver_mode := Spf
  | "ak" -> solver_mode := Ak
  | _ -> raise (Arg.Bad("Unknown solver"))

let speclist = [
  ("-s", Arg.Symbol (["mcf"; "vlb"; "ecmp"; "spf"; "ak"], 
		    choose_solver), ": set solver strategy");
  ("-t", Arg.Set_string topo_string, ": set topology file");
  ("-i", Arg.Set_int iterations, ": set number of iterations");
]

let missing_args () = match (!solver_mode, !topo_string, !iterations) with
  | (NaS,_,_) -> true
  | (_,"",_) -> true
  | (_,_,0) -> true
  | _ -> false
	
let select_algorithm solver = match solver with
  | Mcf -> Kulfi_Routing.Mcf.solve
  | Vlb -> Kulfi_Routing.Mcf.solve
  | Ecmp -> Kulfi_Routing.Mcf.solve
  | Spf -> Kulfi_Routing.Mcf.solve
  | Ak -> Kulfi_Routing.Mcf.solve
  | _ -> assert false

		 
let main =
  Arg.parse speclist print_endline usage;
  if (missing_args ()) then Printf.printf "%s" usage
  else
    begin
      Printf.printf "Kulfi Simulate";
      let topo = Parse.from_dotfile !topo_string in
	  let host_set = VertexSet.filter (Topology.vertexes topo)
					  ~f:(fun v ->
					      let label = Topology.vertex_to_label topo v in
            Node.device label = Node.Host) in
	  let hosts = Topology.VertexSet.elements host_set in
	  let demand_matrix = Simulate_Demands.create_sparse hosts 0.1 100 in
	  let pairs = Simulate_Demands.get_demands demand_matrix in
	  Printf.printf "# hosts = %d\n" (Topology.VertexSet.length host_set);
	  Printf.printf "# pairs = %d\n" (List.length pairs);
	  Printf.printf "# total vertices = %d\n" (Topology.num_vertexes topo);
	  let at = ref (make_auto_timer ()) in
	  let times = ref (make_running_stat ()) in
	  let solve = select_algorithm !solver_mode in
	  let data = ref (make_data "Iteratives Vs Time") in
	  let rec loop n = 
	    if n > !iterations then
	      ()
	    else
	      begin		
		at := start !at ;
		let _ = solve topo pairs SrcDstMap.empty in 
		at := stop !at ;
		times := push !times (get_time_in_seconds !at) ;
		loop (n+1)
	      end
	  in
	  loop 1;
	  data := add_record !data (solver_to_string !solver_mode)
			     {iteration = !iterations;
			      time=(get_mean !times);
			      time_dev=(get_standard_deviation !times); };
	  Printf.printf "%s" (to_string !data "# solver\titer\ttime\tstddev" iter_vs_time_to_string) 
			     
    end
		  
let _ = main 

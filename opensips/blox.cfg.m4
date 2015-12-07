# /* Blox is an Opensource Session Border Controller
#  * Copyright (c) 2015-2018 "Blox" [http://www.blox.org]
#  * 
#  * This file is part of Blox.
#  * 
#  * Blox is free software: you can redistribute it and/or modify
#  * it under the terms of the GNU General Public License as published by
#  * the Free Software Foundation, either version 3 of the License, or
#  * (at your option) any later version.
#  * 
#  * This program is distributed in the hope that it will be useful,
#  * but WITHOUT ANY WARRANTY; without even the implied warranty of
#  * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
#  * GNU General Public License for more details.
#  * 
#  * You should have received a copy of the GNU General Public License
#  * along with this program. If not, see <http://www.gnu.org/licenses/> 
#  */


# ----------- global configuration parameters ------------------------
include_file "blox-glob.cfg"

include_file "blox-listen.cfg"

include_file "blox-tls.cfg"

# ------------------ module loading ----------------------------------
include_file "blox-modules.cfg"

# ----------------- setting module-specific parameters ---------------
include_file "blox-modparam.cfg"

startup_route {
    avp_db_query("SELECT codec FROM  blox_codec","$avp(codec)");
    cache_store("local", "allomtscodec", "$avp(codec)");
}

route[ALLOMTSLOAD] {
    avp_db_query("SELECT codec FROM  blox_codec","$avp(codec)");
    cache_store("local", "allomtscodec", "$avp(codec)");
}

# main routing logic
route {
    xlog("L_INFO", "Received $Ri:$Rp Got $rm $fu/$ru/$si:$sp/$du/$retcode\n" );

    force_rport();

    # initial sanity checks
    if (pcre_match_group("$ua", "0")) { #Group: 0 is blacklist
        xlog("L_INFO", "Dropping SIP scanner $ua\n");
        exit;
    }

    if (msg:len >= MAX_SIP_MSG_LENGTH ) {
        xlog("L_ERR", "Too BIG $rm $ml: $fu/$ru/$si/$du/$retcode\n" );
        sl_send_reply("513", "Message too big");
        exit;
    };

    if (!mf_process_maxfwd_header("MAX_SIP_MAXFWD")) {
        sl_send_reply("483","Too Many Hops");
        exit;
    };

    $avp(SIPProfile) = "sip:" + $Ri + ":" + $Rp + ";transport=" + $pr;
    
    xdbg("BLOX_DBG: Getting Profile for $avp(SIPProfile)\n");
    if(cache_fetch("local","LAN:$avp(SIPProfile)",$avp(LAN))) { #/* Try loading from cache */
        xdbg("BLOX_DBG: Got Profile info from cache LAN:$avp(SIPProfile) $avp(WAN)\n");
        $avp(LANIP) = $(avp(SIPProfile){uri.host});
        $avp(LANPORT) = $(avp(SIPProfile){uri.port});
    } else if(cache_fetch("local","WAN:$avp(SIPProfile)",$avp(WAN))) { #/* Try loading from cache */
        xdbg("BLOX_DBG: Got Profile info from cache WAN:$avp(SIPProfile) $avp(WAN)\n");
        $avp(WANIP) = $(avp(SIPProfile){uri.host});
        $avp(WANPORT) = $(avp(SIPProfile){uri.port});
    } else if(avp_db_load("$avp(SIPProfile)","$avp(LAN)/blox_profile_config")) { #/* Try loading from db */
        $avp(LANIP) = $(avp(SIPProfile){uri.host});
        $avp(LANPORT) = $(avp(SIPProfile){uri.port});
        cache_store("local","LAN:$avp(SIPProfile)", "$avp(LAN)");
        #cache_store("local","$avp(LAN)", "$avp(SIPProfile)"); #/* Store the reverse of key/value too */
    } else if (avp_db_load("$avp(SIPProfile)","$avp(WAN)/blox_profile_config")) { #/* Try loading from db */
        $avp(WANIP) = $(avp(SIPProfile){uri.host});
        $avp(WANPORT) = $(avp(SIPProfile){uri.port});
        cache_store("local","WAN:$avp(SIPProfile)", "$avp(WAN)");
        #cache_store("local","$avp(WAN)", "$avp(SIPProfile)"); #/* Store the reverse of key/value too */
    }

    if(!($avp(LAN) || $avp(WAN))) {
        xlog("L_INFO", "Unknown SIP Profile $avp(SIPProfile) ==> $avp(LAN) $avp(WAN)\n");
        sl_send_reply("603", "Declined");
        exit;
    }

    xdbg("BLOX_DBG: Got ($pr:$Ri:$Rp) $avp(SIPProfile): Index:$avp(LAN):$avp(WAN):");

    if (is_method("OPTIONS") || is_method("SUBSCRIBE")) {
    	xdbg("BLOX_DBG: Not support OPTIONS/SUBSCRIBE\n");
        append_hf("Allow: INVITE, ACK, REFER, NOTIFY, CANCEL, BYE, REGISTER" );
        sl_send_reply("405", "Method Not Allowed");
        exit;
    }

    if(method == "REGISTER") {
        route(ROUTE_REGISTER);
    };

    if (is_method("BYE") || is_method("CANCEL")) {
        $avp(cfgparam) = "cfgparam" ;
        avp_db_delete("$hdr(call-id)","$avp($avp(cfgparam))") ;
    }

    # subsequent messages withing a dialog should take the
    # path determined by record-routing
    if (loose_route()) {
        xdbg("BLOX_DBG: PRE-ROUTING SIP Method $rm received from $fu $si $sp to $ru ($avp(rcv))\n");
        # mark routing logic in request
        append_hf("P-hint: rr-enforced\r\n");
        if (is_method("BYE|CANCEL")) {
            if($dlg_val(MediaProfileID)) {
                $avp(MediaProfileID) = $dlg_val(MediaProfileID) ;
                if($avp(setid)) {
                    rtpengine_delete();
                }
                xlog("L_INFO", "Mediaprofile stopping the $avp(MediaProfileID)\n");
            }
            $avp(resource) = "resource" + "-" + $ft ;
            route(DELETE_ALLOMTS_RESOURCE);
        };
        if($avp(LAN)) {
            route(LAN2WAN);
        } else {
            route(WAN2LAN);
        }
        exit;
    };

    if (has_totag() && (uri == myself)  && is_method("INVITE|ACK|BYE|UPDATE|REFER|NOTIFY")) {
         if(match_dialog()) {
            xdbg("BLOX_DBG: In-Dialog tophide - $dlg_val(ucontact) : $dlg_val(dcontact) - $DLG_dir\n");
            append_hf("P-hint: $DLG_dir\r\n");
            if (is_method("BYE")) {
                if($dlg_val(MediaProfileID)) {
                    $avp(MediaProfileID) = $dlg_val(MediaProfileID) ;
                    if($avp(setid)) {
                        rtpengine_delete();
                    }
                    xlog("L_INFO", "Mediaprofile stopping the $avp(MediaProfileID)\n");
                }
                $avp(resource) = "resource" + "-" + $ft ;
                route(DELETE_ALLOMTS_RESOURCE);
                $avp(resource) = "resource" + "-" + $tt ;
                route(DELETE_ALLOMTS_RESOURCE);
                if(method == "BYE") {
                    route(ROUTE_BYE);
                }
            };
            if($avp(LAN)) {
                route(LAN2WAN);
            } else {
                route(WAN2LAN);
            }
            exit;
         };
         if(method == "NOTIFY") { /* Only REFER-NOTIFY, Not SUBSCRIBE */
            sl_send_reply("405", "Method Not Allowed");
            append_hf("Allow: INVITE, ACK, REFER, CANCEL, BYE, REGISTER" );
            exit;
         }
    };

    if(method == "INVITE") {
        route(ROUTE_INVITE);
    }

    if (method == "CANCEL") {
        route(ROUTE_CANCEL);
    }

    if ( method == "ACK" ) { #already dialog handled, this should be dropped
        xlog("L_INFO", "Dropping SIP Method $rm received from $fu $si $sp to $ru ($avp(rcv))\n"); /* Dont know what to do */
    	t_check_trans();  # stops the retransmission
    	exit;
    }

    #drop();
    #xlog("L_INFO", "Dropping SIP Method $rm received from $fu $si $sp to $ru ($avp(rcv))\n"); /* Dont know what to do */
    #exit;
}

# ----------- Experimentation routers ------------------------
failure_route[missed_call] {
    if (t_was_cancelled()) {
        $avp(MediaProfileID) = $dlg_val(MediaProfileID) ;
        if($avp(setid)) {
            rtpengine_delete();
        }
        $avp(resource) = "resource" + "-" + $ft ;
        route(DELETE_ALLOMTS_RESOURCE);
        exit;
    }
}

failure_route[UAC_AUTH_FAIL] {
    xdbg("BLOX_DBG: In failure_route UAC_AUTH_FAIL");
        
    if (t_check_status("40[17]")) {
        # have we already tried to authenticate?
        if (isflagset(88)) {
            t_reply("503","Authentication failed");
            exit;
        }
        if(uac_auth()) {
            $avp(uuid) = "cseq-" + $ft ;
            setflag(88);
            xdbg("BLOX_DBG: Return code is $retcode");
            if(!cache_fetch("local","$avp(uuid)",$avp(CSEQ_OFFSET))) {
                $avp(CSEQ_OFFSET) = 1;
            }
            $var(toffset) = $avp(CSEQ_OFFSET) ;
            $var(offset) = $(var(toffset){s.int}) ;
            $var(c) = $(cs{s.int}) + $var(offset);
            subst("/CSeq: (.*) (.*)$/CSeq: $var(c) \2/");
            cache_store("local","$avp(uuid)","$avp(CSEQ_OFFSET)");

            $avp(uuid) = "auth-" + $ft ;
            cache_store("local","$avp(uuid)","$avp(auth)");

            xdbg("BLOX_DBG: Got Challenged $var(c): $avp(CSEQ_OFFSET)\n");
            t_on_failure("UAC_AUTH_FAIL");
            append_branch();

            xdbg("BLOX_DBG: failure_route the cseq offset for $mb\n") ;
            #t_relay();
        } else {
            xlog("L_INFO", "uac_auth failed\n") ;
        }
    }
}


###########################################################################################
# ----------- SIP Method based routers ------------------------
include_file "blox-register.cfg"
include_file "blox-invite.cfg"
include_file "blox-cancel.cfg"
include_file "blox-bye.cfg"
###########################################################################################
# ----------- SBC Feature routers ------------------------
include_file "blox-lcr.cfg"
include_file "blox-cac.cfg"
include_file "blox-enum.cfg"
include_file "blox-sip-header-manipulation.cfg"
###########################################################################################
# ----------- SIP Profile based routers without MTS ------------------------
import_file  "blox-allomts-dummy.cfg"
import_file  "blox-lan2wan.cfg"
import_file  "blox-wan2lan.cfg"
###########################################################################################
# ----------- AlloMTS Transcoding routers ------------------------
import_file  "blox-allomts.cfg"
import_file  "blox-lan2wan-allomts.cfg"
import_file  "blox-wan2lan-allomts.cfg"
###########################################################################################
# ----------- Addon Module ------------------------
import_file  "blox-humbug.cfg"
###########################################################################################

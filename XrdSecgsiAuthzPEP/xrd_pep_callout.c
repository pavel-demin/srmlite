/******************************************************************************/
/*                                                                            */
/*                      x r d _ p e p _ c a l l o u t . c                     */
/*                                                                            */
/* (c) 2013 by Juan Cabrera and Pavel Demin                                   */
/* Centre for Cosmology, Particle Physics and Phenomenology                   */
/* Université catholique de Louvain, Belgium                                  */
/******************************************************************************/

////////////////////////////////////////////////////////////////////////////////
// XROOTD Service PEP client Callout Function                                 //
//                                                                            //
// This function provides a authorization/mapping callout to the              //
// xrootd daemon via ARGUS Service PEP daemon.                                //
//                                                                            //
// @va_list ap                                                                //
//        This function, like all functions using the Globus Callout API, is  //
//        passed parameter though the variable argument list facility. The    //
//        actual arguments that are passed are:                               //
//                                                                            //
//        - The DN of the user trying to conect. This                         //
//          parameter is of type char *                                       //
//        - The certificate of the user trying to conect in PEM format. This  //
//          parameter is of type char *                                       //
//          invocation. This parameter is of type gss_ctx_id_t.               //
//        - The name of the service being invoced. This parameter should be   //
//          passed as a NUL terminated string. If no service string is        //
//          available a value of NULL should be passed in its stead. This     //
//          parameter is of type char *                                       //
//        - A pointer to a buffer. This buffer will contain the mapped (local)//
//          identity (NUL terminated string) upon successful return. This     //
//          parameter is of type char *.                                      //
//        - The length of the above mentioned buffer. This parameter is of    //
//          type unsigned int.                                                //
//                                                                            //
// It would be like to call:                                                  //
// xrd_pep_callout(char *       peer_name,                                    //
//                 char *       cert_chain,                                   //
//                 char *       service,                                      //
//                 char *       identity_buffer,                              //
//                 unsigned int identity_buffer_l)                            //
//                                                                            //
// @return                                                                    //
//        GLOBUS_SUCCESS upon success                                         //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////

#include "gsi_pep_callout.c"

EXTERN_C_BEGIN

globus_result_t xrd_pep_callout(va_list ap)
{
    // va_list params
    char *                              peer_name;
    char *                              cert_chain;
    char *                              service;
    char *                              identity_buffer;
    unsigned int                        identity_buffer_l;

    // internal variables
    char * local_identity= NULL;
    globus_result_t result = GLOBUS_SUCCESS;

    // function name for error macros
    static char * _function_name_ = "xrd_pep_callout";

    // active module
    result= globus_module_activate(GSI_PEP_CALLOUT_MODULE);
    if (result!=GLOBUS_SUCCESS) {
        GSI_PEP_CALLOUT_ERROR(
            result,
            GSI_PEP_CALLOUT_ERROR_MODULE_ACTIVATION,
            ("Module GSI_PEP_CALLOUT_MODULE activation failed"));
        goto error;
    }

    GSI_PEP_CALLOUT_DEBUG_FCT_BEGIN(1);

    // process va_list arguments
    peer_name= va_arg(ap, char *);
    cert_chain= va_arg(ap, char *);
    service= va_arg(ap, char *);
    identity_buffer= va_arg(ap, char *);
    identity_buffer_l= va_arg(ap, unsigned int);

    GSI_PEP_CALLOUT_DEBUG_PRINTF(2,("peer_name: %s\n", peer_name == NULL ? "NULL" : peer_name));
    GSI_PEP_CALLOUT_DEBUG_PRINTF(3,("cert_chain: %s\n", cert_chain == NULL ? "NULL" : cert_chain));
    GSI_PEP_CALLOUT_DEBUG_PRINTF(2,("service: %s\n", service == NULL ? "NULL" : service));

    const char * config= gsi_pep_callout_config_getfilename();
    GSI_PEP_CALLOUT_DEBUG_PRINTF(2,("Using config: %s", config == NULL ? "NULL" : config));


    syslog_info("Authorizing DN %s", peer_name);

    // configure PEP client
    if ((result= pep_client_configure()) != GLOBUS_SUCCESS) {
        GSI_PEP_CALLOUT_ERROR(
                result,
                GSI_PEP_CALLOUT_ERROR_PEP_CLIENT,
                ("Failed to configure PEP client"));
        goto error;
    }

    if ((result= pep_client_authorize(peer_name,cert_chain,service,&local_identity)) !=  GLOBUS_SUCCESS) {
        GSI_PEP_CALLOUT_ERROR(
            result,
            GSI_PEP_CALLOUT_ERROR_AUTHZ,
            ("Can not map %s to local identity", peer_name));
        goto error;
    }

    if(strlen(local_identity) + 1 > identity_buffer_l)
    {
        GSI_PEP_CALLOUT_ERROR(
            result,
            GSI_PEP_CALLOUT_ERROR_IDENTITY_BUFFER,
            ("Local identity length: %d Buffer length: %d\n",
             strlen(local_identity), identity_buffer_l));
    }
    else
    {
        strncpy(identity_buffer,local_identity,identity_buffer_l);
        GSI_PEP_CALLOUT_DEBUG_PRINTF(2, ("%s mapped to %s\n", peer_name, identity_buffer));
        syslog_info("DN %s authorized and mapped to local username %s",peer_name,identity_buffer);
    }
    free(local_identity);


error:
    // in argus-gsi-pep-callout those are internal variables here they are 
    // function arguments we can not free them xrootd will not be happy
    //if (peer_name) free(peer_name);
    //if (cert_chain) free(cert_chain);

    //XXX
    syslog_debug("%s: result=%d",_function_name_,result);
    if (result!=GLOBUS_SUCCESS) {
        globus_object_t *error= globus_error_get(result);
        if (error) {
            char * error_string= globus_error_print_chain(error);
            if (error_string) {
                syslog_error("%s: %s", _function_name_, error_string);
            }
        }
    }

    globus_module_deactivate(GSI_PEP_CALLOUT_MODULE);

    GSI_PEP_CALLOUT_DEBUG_FCT_RETURN(1,result);

    return result;
}


EXTERN_C_END


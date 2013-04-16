/******************************************************************************/
/*                                                                            */
/*               X r d S e c g s i A u t h z F u n P E P . c c                */
/*                                                                            */
/* (c) 2013 by Juan Cabrera and Pavel Demin                                   */
/* Centre for Cosmology, Particle Physics and Phenomenology                   */
/* Université catholique de Louvain, Belgium                                  */
/******************************************************************************/

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Xrootd Authz Plug-in for gsi protocol based on ARGUS authentification.     //
// in your xrootd configuration file (/etc/xrootd/xrootd-clustered.cfg),      //
// it can be parametrized like:                                               //
//                                                                            //
// sec.protocol /usr/lib64 gsi -d:0 -crl:3 \                                  //
//   -authzfun:libXrdSecgsiAuthzPEP.so \                                      //
//   -authzfunparms:debug=0&conf=/etc/grid-security/xrd/gsi-pep-callout.conf \//
//   -gmapopt:10 -gmapto:0 -ca:2                                              //
//                                                                            //
//   /usr/lib64  libpath where libXrdSecgsiAuthzPEP.so is present             //
//   -d xrootd debug level                                                    //
//      0 => PRINT (only errors)                                              //
//      1 => PRINT+NOTIFY                                                     //
//      2 => PRINT+NOTIFY+DEBUG                                               //
//      3 => PRINT+NOTIFY+DEBUG+DUMP                                          //
//   -crl:3 => require an up-to-date CRL for each CA                          //
//   -authzfunparm:                                                           //
//        debug=[0...9] GLOBUS and PEP_CALLOUT debug level                    //
//              if not present, use defaut values.                            //
//              log is send to xroot log file (/var/log/xrootd/xrootd.log)    //
//        conf= pep callout configuration file.                               //
//              It must contain a hostkey with xrootd read permission         //
//   -gmapopt:10 => client DN will be used as user identifier                 //
//   -gmapto:0 => internal mapping is turned off.                             //
//   -ca:2 always verify the CA in the chain, failing when not possible       //
//                                                                            //
//   Other arguments with its default values you can use :                    //
//   -cert:/etc/grid-security/xrd/xrdcert.pem                                 //
//   -key:/etc/grid-security/xrd/xrdkey.pem                                   //
//   -certdir:/etc/grid-security/certificates                                 //
//                                                                            //
// Configuration:                                                             //
//                                                                            //
// Copy you hostkey.pem, hostcert.pem and gsi-pep-callout.conf files like :   //
// -rw-r--r-- 1 xrootd xrootd /etc/grid-security/xrd/xrdcert.pem              //
// -rw-r--r-- 1 xrootd xrootd /etc/grid-security/xrd/xrdkey.pem               //
// -r-------- 1 xrootd xrootd /etc/grid-security/xrd/gsi-pep-callout.conf     //
// set owner and acces permissions                                            //
//                                                                            //
// modify /etc/grid-security/xrd/gsi-pep-callout.conf with:                   //
// pep_ssl_client_cert /etc/grid-security/xrd/xrdcert.pem                     //
// pep_ssl_client_key /etc/grid-security/xrd/xrdkey.pem                       //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <pwd.h>
#include <dlfcn.h>
#include <stdarg.h>

#include <globus_common.h>

#include "xrootd/XrdSys/XrdSysHeaders.hh"
#include "xrootd/XrdSys/XrdSysPthread.hh"
#include "xrootd/XrdSec/XrdSecEntity.hh"
#include "xrootd/XrdOuc/XrdOucString.hh"
#include "xrootd/XrdOuc/XrdOucEnv.hh"
#include "xrootd/XrdOuc/XrdOucLock.hh"
#include "xrootd/XrdOuc/XrdOucTrace.hh"

#include "xrootd/XrdSecgsi/XrdSecgsiTrace.hh"
#include "xrootd/XrdCrypto/XrdCryptoX509Chain.hh"
#include "xrootd/XrdCrypto/XrdCryptosslAux.hh"

extern "C"
{

////////////////////////////////////////////////////////////////////////////////
// xrd_pep_callout is a modified version of argus_pep_callout function        //
// va_list must have this arguments:                                          //
//  char *       peer_name,                                                   //
//  char *       cert_chain,                                                  //
//  char *       service,                                                     //
//  char *       identity_buffer,                                             //
//  unsigned int identity_buffer_l                                            //
////////////////////////////////////////////////////////////////////////////////

globus_result_t xrd_pep_callout( va_list );

globus_result_t xrd_pep_callout_list(int argc, ...) 
{
  va_list xrd_pep_callout_args;
  va_start(xrd_pep_callout_args,argc);
  globus_result_t result = GLOBUS_SUCCESS;

  result = xrd_pep_callout(xrd_pep_callout_args);

  va_end(xrd_pep_callout_args);

  return result;
}

//
// The following functions are called by the authz plug-in driver.
//
int XrdSecgsiAuthzInit(const char *cfg);
int XrdSecgsiAuthzFun(XrdSecEntity &entity);
int XrdSecgsiAuthzKey(XrdSecEntity &entity, char **key);
////////////////////////////////////////////////////////////////////////////////
//                        XrdSecEntity structure                              //
////////////////////////////////////////////////////////////////////////////////
//char   prot[XrdSecPROTOIDSIZE];  // Protocol used                           //
//char   *name;                    // Entity's name (DN)                      //
//char   *host;                    // Entity's host name                      //
//char   *vorg;                    // Entity's virtual organization           //
//char   *role;                    // Entity's role                           //
//char   *grps;                    // Entity's group names                    //
//char   *endorsements;            // Protocol specific endorsements          //
//char   *creds;                   // Raw client credentials or certificate   //
//int     credslen;                // Length of the 'cert' field              //
//char   *moninfo;                 // Additional information for monitoring   //
//char   *tident;                  // Trace identifier (do not touch)         //
////////////////////////////////////////////////////////////////////////////////

XrdSysMutex mutex;

}

/******************************************************************************/
/*                     X r d S e c g s i A u t h z F u n                      */
/******************************************************************************/

/* Uses Argus authentification procedure

   Return GLOBUS_SUCCESS upon success
          GLOBUS ERROR ID on error
*/

int XrdSecgsiAuthzFun(XrdSecEntity &entity)
{

  EPNAME("XrdSecgsiAuthzFun");

  globus_result_t result = GLOBUS_SUCCESS;

  // Grab the global mutex.
  XrdSysMutexHelper lock(&mutex);

  DEBUG("entity.prot='"<< (entity.prot ? entity.prot : "null") << "'.");
  NOTIFY("entity.name='"<< (entity.name ? entity.name : "null") << "'.");
  NOTIFY("entity.host='"<< (entity.host ? entity.host : "null") << "'.");
  NOTIFY("entity.vorg='"<< (entity.vorg ? entity.vorg : "null") << "'.");
  NOTIFY("entity.role='"<< (entity.role ? entity.role : "null") << "'.");
  DEBUG("entity.grps='"<< (entity.grps ? entity.grps : "null") << "'.");
  DEBUG("entity.endorsements='"<< (entity.endorsements ? entity.endorsements : "null") << "'.");
  DEBUG("entity.creds='"<< (entity.creds ? entity.creds : "null") << "'.");
  DEBUG("entity.moninfo='"<< (entity.moninfo ? entity.moninfo : "null") << "'.");
  DEBUG("entity.tident='"<< (entity.tident ? entity.tident : "null") << "'.");


  char * service= strdup("file");
  size_t identity_l= 1024;
  char identity[1024];

  result = xrd_pep_callout_list(5,entity.name,entity.creds,service,identity,identity_l);

  if (result!=GLOBUS_SUCCESS)
  { globus_object_t *error= globus_error_get(result);
    char * error_string= globus_error_print_chain(error);
    PRINT("GLOBUS ERROR: "<<result<<" => " << error_string );
  }

  // DN is in 'name' (--gmapopt=10), move it over to moninfo ...
  free(entity.moninfo);
  entity.moninfo = entity.name;
  // ... and copy the local username into 'name'.
  entity.name = strdup(identity);

//
// All done
//
  return result;
}

/******************************************************************************/
/*                     X r d S e c g s i A u t h z K e y                      */
/******************************************************************************/

int XrdSecgsiAuthzKey(XrdSecEntity &entity, char **key)
{
  // Return key by which entity.creds will be hashed.
  // use DN + VO endorsements.

  EPNAME("XrdSecgsiAuthzKey");

  // Must have got something
  if (!key) {
    PRINT("ERROR: 'key' must be defined.");
    return -1;
  }
  if (!entity.name) {
    PRINT("ERROR: 'entity.name' must be defined (-gmapopt=10).");
    return -1;
  }

  DEBUG("entity.name='"<< (entity.name ? entity.name : "null") << "'.");
  DEBUG("entity.vorg='"<< (entity.vorg ? entity.vorg : "null") << "'.");
  DEBUG("entity.role='"<< (entity.role ? entity.role : "null") << "'.");
  DEBUG("entity.moninfo='"<< (entity.moninfo ? entity.moninfo : "null") << "'.");
  DEBUG("entity.endorsements='"<< (entity.endorsements ? entity.endorsements : "null") << "'.");

  // Return DN (in name) + endrosments as the key:
  XrdOucString s(entity.name);
  if (entity.endorsements) {
    s += "::";
    s += entity.endorsements;
  }
  *key = strdup(s.c_str());

  DEBUG("Returning '" << s << "' of length " << s.length() << " as key.");

  return s.length() + 1;

}

/******************************************************************************/
/*                    X r d S e c g s i A u t h z I n i t                     */
/******************************************************************************/

int XrdSecgsiAuthzInit(const char *cfg)
{
  // default values
  // force PEP format
  const  int   g_certificate_format = 1;
  // pep-callout configuration file must contain hostkey with xrootd read permission
  // /etc/grid-security/xrd/xrdkey.pem
  globus_module_setenv("GSI_PEP_CALLOUT_CONF","/etc/grid-security/xrd/gsi-pep-callout.conf");

   // Return:
   //   -1 on falure
   //    0 to get credentials in raw form
   //    1 to get credentials in PEM base64 encoded form

   EPNAME("XrdSecgsiAuthzInit");
   XrdOucEnv *envP;
   char cfgbuff[2048], *sP;
   int i;

   NOTIFY("cfg='"<< (cfg ? cfg : "null") << "'.");

// The configuration string may mistakingly include other parms following
// the auzparms. So, trim the string.
//
   if (cfg)
      {i = strlen(cfg);
       if (1 >= (int)sizeof(cfgbuff)) i = sizeof(cfgbuff)-1;
       strncpy(cfgbuff, cfg, i);
       cfgbuff[i] = 0;
       if ((sP = index(cfgbuff, ' '))) *sP = 0;
      }
   if (!cfg || !(*cfg)) return g_certificate_format;

// Parse the config line (it's in cgi format)
//
   envP = new XrdOucEnv(cfgbuff);

// Set gsi and globus debug value
//
   if (envP->Get("debug"))
   { char * debug = strdup(envP->Get("debug"));
     DEBUG("setting debug level in GLOBUS and GSI_PEP_CALLOUT to " << debug);
     globus_module_setenv("GLOBUS_CALLOUT_DEBUG_LEVEL",debug);
     globus_module_setenv("GLOBUS_GSSAPI_DEBUG_LEVEL",debug);
     globus_module_setenv("GSI_PEP_CALLOUT_DEBUG_LEVEL",debug);

     // stderr is send to default log file (/var/log/xrootd/xrootd.log)
     globus_module_setenv("GSI_PEP_CALLOUT_DEBUG_FILE","stderr");
   }

   DEBUG("getting conf file");
   if (envP->Get("conf"))
   {
     char * conf = strdup(envP->Get("conf"));
     DEBUG("setting pep callout config file to " << conf);
     globus_module_setenv("GSI_PEP_CALLOUT_CONF",conf);
   }

// All done with environment
//
   delete envP;

// All done.
//
   return g_certificate_format;
}



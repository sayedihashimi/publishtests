using Microsoft.Owin;
using Owin;

[assembly: OwinStartupAttribute(typeof(Wap2015.Startup))]
namespace Wap2015
{
    public partial class Startup
    {
        public void Configuration(IAppBuilder app)
        {
            ConfigureAuth(app);
        }
    }
}
